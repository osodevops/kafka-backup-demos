package com.osodevops.demo;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.streams.KafkaStreams;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.StreamsConfig;
import org.apache.kafka.streams.kstream.KStream;
import org.apache.kafka.streams.kstream.Produced;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.time.Instant;
import java.util.Properties;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Kafka Streams PITR Demo Application
 *
 * Demonstrates point-in-time recovery with Kafka Streams:
 * - Consumes from 'orders' topic
 * - Filters out invalid (BAD) orders
 * - Enriches valid orders with processing timestamp
 * - Writes to 'orders_enriched' topic
 *
 * Usage:
 *   mvn clean package
 *   java -jar target/kafka-streams-pitr-demo.jar [bootstrap-servers]
 *
 * Or with Maven:
 *   mvn exec:java -Dexec.args="localhost:9092"
 */
public class DemoKafkaStreamsPITR {

    private static final Logger log = LoggerFactory.getLogger(DemoKafkaStreamsPITR.class);
    private static final ObjectMapper mapper = new ObjectMapper();

    // Counters for demo visibility
    private static final AtomicLong processedCount = new AtomicLong(0);
    private static final AtomicLong filteredCount = new AtomicLong(0);
    private static final AtomicLong enrichedCount = new AtomicLong(0);

    public static void main(String[] args) {
        String bootstrapServers = args.length > 0 ? args[0] : "localhost:9092";

        log.info("==============================================");
        log.info("   Kafka Streams PITR Demo");
        log.info("==============================================");
        log.info("Bootstrap servers: {}", bootstrapServers);
        log.info("Input topic: orders");
        log.info("Output topic: orders_enriched");
        log.info("");

        Properties props = createStreamConfig(bootstrapServers);
        StreamsBuilder builder = new StreamsBuilder();

        // Build the topology
        buildTopology(builder);

        // Create and start the streams application
        KafkaStreams streams = new KafkaStreams(builder.build(), props);

        // Handle shutdown gracefully
        final CountDownLatch latch = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            log.info("");
            log.info("==============================================");
            log.info("   Shutting Down");
            log.info("==============================================");
            log.info("Total processed: {}", processedCount.get());
            log.info("Filtered (bad):  {}", filteredCount.get());
            log.info("Enriched:        {}", enrichedCount.get());
            streams.close();
            latch.countDown();
        }));

        try {
            streams.start();
            log.info("Streams application started. Press Ctrl+C to stop.");
            log.info("");
            latch.await();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static Properties createStreamConfig(String bootstrapServers) {
        Properties props = new Properties();
        props.put(StreamsConfig.APPLICATION_ID_CONFIG, "orders-streams");
        props.put(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(StreamsConfig.DEFAULT_KEY_SERDE_CLASS_CONFIG, Serdes.String().getClass());
        props.put(StreamsConfig.DEFAULT_VALUE_SERDE_CLASS_CONFIG, Serdes.String().getClass());

        // Processing guarantees
        props.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG, StreamsConfig.AT_LEAST_ONCE);

        // Commit interval (controls offset commit frequency)
        props.put(StreamsConfig.COMMIT_INTERVAL_MS_CONFIG, 1000);

        // State directory (for recovery)
        props.put(StreamsConfig.STATE_DIR_CONFIG, "/tmp/kafka-streams-pitr-demo");

        return props;
    }

    private static void buildTopology(StreamsBuilder builder) {
        KStream<String, String> orders = builder.stream("orders");

        orders
            // Log incoming records
            .peek((key, value) -> {
                processedCount.incrementAndGet();
                log.debug("Received: key={}, value={}", key, value);
            })

            // Filter out bad/invalid orders
            .filter((key, value) -> {
                boolean isValid = isValidOrder(value);
                if (!isValid) {
                    filteredCount.incrementAndGet();
                    log.warn("Filtered BAD order: {}", value);
                }
                return isValid;
            })

            // Enrich valid orders
            .mapValues(value -> enrichOrder(value))

            // Log enriched records
            .peek((key, value) -> {
                enrichedCount.incrementAndGet();
                log.info("Enriched order: {}", value);
            })

            // Write to output topic
            .to("orders_enriched", Produced.with(Serdes.String(), Serdes.String()));
    }

    /**
     * Check if an order is valid.
     * Invalid orders contain "BAD" or "CORRUPTED" in the value.
     */
    private static boolean isValidOrder(String value) {
        if (value == null) return false;

        String upperValue = value.toUpperCase();
        return !upperValue.contains("BAD") &&
               !upperValue.contains("CORRUPTED") &&
               !upperValue.contains("INVALID");
    }

    /**
     * Enrich an order with processing metadata.
     */
    private static String enrichOrder(String value) {
        try {
            JsonNode node = mapper.readTree(value);

            if (node.isObject()) {
                ObjectNode enriched = (ObjectNode) node;
                enriched.put("enriched", true);
                enriched.put("processed_at", Instant.now().toString());
                enriched.put("processor", "orders-streams");
                return mapper.writeValueAsString(enriched);
            }
        } catch (Exception e) {
            log.debug("Could not parse as JSON, enriching as plain text");
        }

        // Fallback for non-JSON messages
        return value + ",enriched=" + Instant.now().toEpochMilli();
    }
}
