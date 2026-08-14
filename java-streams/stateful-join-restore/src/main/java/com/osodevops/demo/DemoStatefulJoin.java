package com.osodevops.demo;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.common.utils.Bytes;
import org.apache.kafka.streams.KafkaStreams;
import org.apache.kafka.streams.KeyValue;
import org.apache.kafka.streams.StoreQueryParameters;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.StreamsConfig;
import org.apache.kafka.streams.Topology;
import org.apache.kafka.streams.kstream.Grouped;
import org.apache.kafka.streams.kstream.JoinWindows;
import org.apache.kafka.streams.kstream.KStream;
import org.apache.kafka.streams.kstream.KTable;
import org.apache.kafka.streams.kstream.Materialized;
import org.apache.kafka.streams.kstream.Produced;
import org.apache.kafka.streams.kstream.StreamJoined;
import org.apache.kafka.streams.processor.StateRestoreListener;
import org.apache.kafka.streams.state.KeyValueIterator;
import org.apache.kafka.streams.state.KeyValueStore;
import org.apache.kafka.streams.state.QueryableStoreTypes;
import org.apache.kafka.streams.state.ReadOnlyKeyValueStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Properties;
import java.util.TreeMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Stateful Join Restore Demo Application
 *
 * A deliberately non-trivial Kafka Streams topology used to demonstrate
 * backup and restore of stateful stream processing:
 *
 *   orders (key=order_id)  ─┐
 *                           ├─ inner windowed join (10 min window, 5 min grace)
 *   payments (key=order_id)─┘        │
 *                                    ├─> orders_with_payments
 *                                    └─> groupBy customer_id  [repartition topic]
 *                                        aggregate revenue    [customer-revenue-store]
 *                                        └─> customer_revenue
 *
 * Internal topics created (application.id = stateful-join-demo):
 *   - two join window store changelogs
 *   - customer-revenue-store changelog (compacted)
 *   - customer-revenue repartition topic
 *
 * Determinism: every output field is a pure function of the input records.
 * No wall-clock values are ever emitted, so a replay of the same inputs
 * produces identical join results and aggregates.
 *
 * An embedded HTTP server (port 7071) exposes:
 *   GET /health   - Streams state
 *   GET /state    - sorted dump of customer-revenue-store
 *   GET /counters - processing counters incl. changelog-restored record count
 *
 * Usage:
 *   java -jar target/stateful-join-demo.jar [bootstrap-servers] [state-dir]
 */
public class DemoStatefulJoin {

    private static final Logger log = LoggerFactory.getLogger(DemoStatefulJoin.class);
    private static final ObjectMapper mapper = new ObjectMapper();

    static final String APPLICATION_ID = "stateful-join-demo";
    static final String ORDERS_TOPIC = "orders";
    static final String PAYMENTS_TOPIC = "payments";
    static final String JOIN_OUTPUT_TOPIC = "orders_with_payments";
    static final String REVENUE_OUTPUT_TOPIC = "customer_revenue";
    static final String JOIN_STORE_NAME = "order-payment-join";
    static final String REVENUE_STORE_NAME = "customer-revenue-store";
    static final int HTTP_PORT = 7071;

    // Counters for demo visibility (exposed via /counters)
    private static final AtomicLong consumedOrders = new AtomicLong(0);
    private static final AtomicLong consumedPayments = new AtomicLong(0);
    private static final AtomicLong joined = new AtomicLong(0);
    private static final AtomicLong aggregateUpdates = new AtomicLong(0);
    private static final AtomicLong restoredChangelogRecords = new AtomicLong(0);

    public static void main(String[] args) throws Exception {
        String bootstrapServers = args.length > 0 ? args[0] : "localhost:9092";
        String stateDir = args.length > 1 ? args[1] : "/tmp/kafka-streams-stateful-join-demo";

        log.info("==============================================");
        log.info("   Kafka Streams Stateful Join Restore Demo");
        log.info("==============================================");
        log.info("Bootstrap servers: {}", bootstrapServers);
        log.info("State directory:   {}", stateDir);
        log.info("Input topics:      {}, {}", ORDERS_TOPIC, PAYMENTS_TOPIC);
        log.info("Output topics:     {}, {}", JOIN_OUTPUT_TOPIC, REVENUE_OUTPUT_TOPIC);
        log.info("");

        Properties props = createStreamConfig(bootstrapServers, stateDir);
        StreamsBuilder builder = new StreamsBuilder();
        buildTopology(builder);

        Topology topology = builder.build();
        log.info("Topology:\n{}", topology.describe());

        KafkaStreams streams = new KafkaStreams(topology, props);

        // Count records restored from changelog topics (scenario 2 evidence:
        // state rebuilt from changelogs, not by reprocessing inputs)
        streams.setGlobalStateRestoreListener(new StateRestoreListener() {
            @Override
            public void onRestoreStart(TopicPartition topicPartition, String storeName,
                                       long startingOffset, long endingOffset) {
                log.info("Changelog restore start: store={} partition={} offsets {}..{}",
                        storeName, topicPartition, startingOffset, endingOffset);
            }

            @Override
            public void onBatchRestored(TopicPartition topicPartition, String storeName,
                                        long batchEndOffset, long numRestored) {
                restoredChangelogRecords.addAndGet(numRestored);
            }

            @Override
            public void onRestoreEnd(TopicPartition topicPartition, String storeName,
                                     long totalRestored) {
                log.info("Changelog restore end: store={} partition={} totalRestored={}",
                        storeName, topicPartition, totalRestored);
            }
        });

        HttpServer httpServer = startHttpServer(streams);

        final CountDownLatch latch = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            log.info("");
            log.info("==============================================");
            log.info("   Shutting Down");
            log.info("==============================================");
            log.info("Consumed orders:            {}", consumedOrders.get());
            log.info("Consumed payments:          {}", consumedPayments.get());
            log.info("Joined:                     {}", joined.get());
            log.info("Aggregate updates:          {}", aggregateUpdates.get());
            log.info("Restored changelog records: {}", restoredChangelogRecords.get());
            streams.close(Duration.ofSeconds(30));
            httpServer.stop(0);
            latch.countDown();
        }));

        streams.start();
        log.info("Streams application started. HTTP endpoints on port {}. Press Ctrl+C to stop.", HTTP_PORT);
        latch.await();
    }

    private static Properties createStreamConfig(String bootstrapServers, String stateDir) {
        Properties props = new Properties();
        props.put(StreamsConfig.APPLICATION_ID_CONFIG, APPLICATION_ID);
        props.put(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(StreamsConfig.DEFAULT_KEY_SERDE_CLASS_CONFIG, Serdes.String().getClass());
        props.put(StreamsConfig.DEFAULT_VALUE_SERDE_CLASS_CONFIG, Serdes.String().getClass());
        props.put(StreamsConfig.DEFAULT_TIMESTAMP_EXTRACTOR_CLASS_CONFIG, EventTimeExtractor.class);
        props.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG, StreamsConfig.AT_LEAST_ONCE);
        props.put(StreamsConfig.COMMIT_INTERVAL_MS_CONFIG, 1000);
        props.put(StreamsConfig.STATE_DIR_CONFIG, stateDir);

        // Wait for both inputs so processing follows timestamp order across topics
        props.put(StreamsConfig.MAX_TASK_IDLE_MS_CONFIG, 10000L);

        // Disable caching so every aggregate update reaches the changelog and
        // output topic - more visible state, simpler reasoning for the demo
        props.put(StreamsConfig.STATESTORE_CACHE_MAX_BYTES_CONFIG, 0L);

        // Streams members do not leave the group on close (by design), so a
        // stopped app's members linger for the session timeout, blocking group
        // deletion and offset resets. Shorten it for fast demo turnaround.
        props.put(StreamsConfig.consumerPrefix(ConsumerConfig.SESSION_TIMEOUT_MS_CONFIG), 10000);

        return props;
    }

    private static void buildTopology(StreamsBuilder builder) {
        KStream<String, String> orders = builder.<String, String>stream(ORDERS_TOPIC)
                .peek((key, value) -> consumedOrders.incrementAndGet());

        KStream<String, String> payments = builder.<String, String>stream(PAYMENTS_TOPIC)
                .peek((key, value) -> consumedPayments.incrementAndGet());

        // Inner windowed join on order_id: payment must arrive within 10 minutes
        // of the order (event time). Grace exceeds the demo data's time span so
        // replay interleaving can never drop records as late.
        KStream<String, String> joinedStream = orders.join(
                payments,
                DemoStatefulJoin::joinOrderPayment,
                JoinWindows.ofTimeDifferenceAndGrace(Duration.ofMinutes(10), Duration.ofMinutes(5)),
                StreamJoined.with(Serdes.String(), Serdes.String(), Serdes.String())
                        .withStoreName(JOIN_STORE_NAME)
        ).peek((key, value) -> {
            joined.incrementAndGet();
            log.info("Joined: key={} value={}", key, value);
        });

        joinedStream.to(JOIN_OUTPUT_TOPIC, Produced.with(Serdes.String(), Serdes.String()));

        // Re-key by customer_id (creates a repartition topic - deliberate) and
        // aggregate revenue per customer into a named, changelogged store
        KTable<String, String> revenue = joinedStream
                .groupBy((orderId, value) -> extractField(value, "customer_id"),
                        Grouped.with("customer-revenue", Serdes.String(), Serdes.String()))
                .aggregate(
                        () -> "{}",
                        DemoStatefulJoin::aggregateRevenue,
                        Materialized.<String, String, KeyValueStore<Bytes, byte[]>>as(REVENUE_STORE_NAME)
                                .withKeySerde(Serdes.String())
                                .withValueSerde(Serdes.String())
                );

        revenue.toStream()
                .peek((key, value) -> {
                    aggregateUpdates.incrementAndGet();
                    log.info("Revenue updated: key={} value={}", key, value);
                })
                .to(REVENUE_OUTPUT_TOPIC, Produced.with(Serdes.String(), Serdes.String()));
    }

    /**
     * Join result - a pure function of the two input records. No wall-clock
     * fields, so replays produce byte-identical results.
     */
    private static String joinOrderPayment(String orderJson, String paymentJson) {
        try {
            JsonNode order = mapper.readTree(orderJson);
            JsonNode payment = mapper.readTree(paymentJson);
            ObjectNode result = mapper.createObjectNode();
            result.put("order_id", order.path("order_id").asText());
            result.put("customer_id", order.path("customer_id").asText());
            result.put("amount", order.path("amount").asLong());
            result.put("order_ts", order.path("event_time").asLong());
            result.put("payment_id", payment.path("payment_id").asText());
            result.put("payment_ts", payment.path("event_time").asLong());
            result.put("event_time", Math.max(order.path("event_time").asLong(),
                    payment.path("event_time").asLong()));
            return mapper.writeValueAsString(result);
        } catch (Exception e) {
            log.warn("Failed to join order={} payment={}", orderJson, paymentJson, e);
            return "{\"error\":\"join-failure\"}";
        }
    }

    private static String aggregateRevenue(String customerId, String joinedJson, String aggJson) {
        try {
            JsonNode joinedNode = mapper.readTree(joinedJson);
            JsonNode agg = mapper.readTree(aggJson);
            long total = agg.path("total_revenue").asLong(0);
            long matchedOrders = agg.path("matched_orders").asLong(0);
            ObjectNode result = mapper.createObjectNode();
            result.put("customer_id", customerId);
            result.put("total_revenue", total + joinedNode.path("amount").asLong());
            result.put("matched_orders", matchedOrders + 1);
            return mapper.writeValueAsString(result);
        } catch (Exception e) {
            log.warn("Failed to aggregate for customer={}", customerId, e);
            return aggJson;
        }
    }

    private static String extractField(String json, String field) {
        try {
            return mapper.readTree(json).path(field).asText("unknown");
        } catch (Exception e) {
            return "unknown";
        }
    }

    // ------------------------------------------------------------------
    // HTTP endpoints for demo verification
    // ------------------------------------------------------------------

    private static HttpServer startHttpServer(KafkaStreams streams) throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress(HTTP_PORT), 0);

        server.createContext("/health", exchange ->
                respond(exchange, 200, "{\"state\":\"" + streams.state() + "\"}"));

        server.createContext("/state", exchange -> {
            if (streams.state() != KafkaStreams.State.RUNNING) {
                respond(exchange, 503, "{\"error\":\"streams not RUNNING\",\"state\":\"" + streams.state() + "\"}");
                return;
            }
            try {
                ReadOnlyKeyValueStore<String, String> store = streams.store(
                        StoreQueryParameters.fromNameAndType(REVENUE_STORE_NAME,
                                QueryableStoreTypes.keyValueStore()));
                TreeMap<String, String> sorted = new TreeMap<>();
                try (KeyValueIterator<String, String> it = store.all()) {
                    while (it.hasNext()) {
                        KeyValue<String, String> kv = it.next();
                        sorted.put(kv.key, kv.value);
                    }
                }
                StringBuilder sb = new StringBuilder("{");
                boolean first = true;
                for (var entry : sorted.entrySet()) {
                    if (!first) sb.append(",");
                    sb.append("\"").append(entry.getKey()).append("\":").append(entry.getValue());
                    first = false;
                }
                sb.append("}");
                respond(exchange, 200, sb.toString());
            } catch (Exception e) {
                respond(exchange, 500, "{\"error\":\"" + e.getMessage() + "\"}");
            }
        });

        server.createContext("/counters", exchange -> respond(exchange, 200, String.format(
                "{\"consumed_orders\":%d,\"consumed_payments\":%d,\"joined\":%d," +
                        "\"aggregate_updates\":%d,\"restored_changelog_records\":%d}",
                consumedOrders.get(), consumedPayments.get(), joined.get(),
                aggregateUpdates.get(), restoredChangelogRecords.get())));

        server.start();
        return server;
    }

    private static void respond(HttpExchange exchange, int status, String body) throws IOException {
        byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
}
