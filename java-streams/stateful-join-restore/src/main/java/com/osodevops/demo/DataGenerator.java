package com.osodevops.demo;

import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringSerializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.Properties;

/**
 * Deterministic data generator for the stateful join restore demo.
 *
 * Every field is a pure function of (index, base timestamp, seed), so a rerun
 * with the same arguments produces byte-identical records with identical
 * explicit producer timestamps. That makes "expected vs actual" evidence a
 * plain diff, and makes the record-timestamp preservation check exact.
 *
 * batch mode (scenarios 1 and 2):
 *   100 orders ORD-0001..ORD-0100, customer CUST-1..CUST-10,
 *   event_time = base + i*1000.
 *   Payments: i % 7 != 0 -> matching payment 30 s after the order (joins,
 *   inside the 10-minute window); i % 7 == 0 -> payment 20 minutes after the
 *   order (outside the window, never joins). 86 joined / 14 unmatched.
 *
 * live mode (scenario 3):
 *   Endless rounds: 10 orders, sleep 5 s (deliberate skew), then their 10
 *   payments. A backup taken mid-round captures orders whose payments have
 *   not been produced yet - the inconsistent-cut demonstration.
 *
 * Usage:
 *   java -cp stateful-join-demo.jar com.osodevops.demo.DataGenerator \
 *       <bootstrap-servers> <batch|live> <base_ts_ms> [seed]
 */
public class DataGenerator {

    private static final Logger log = LoggerFactory.getLogger(DataGenerator.class);

    private static final int BATCH_ORDERS = 100;
    private static final int CUSTOMERS = 10;
    private static final long MATCH_DELAY_MS = 30_000L;        // inside 10-min window
    private static final long UNMATCHED_DELAY_MS = 20 * 60_000L; // outside window
    private static final int LIVE_ROUND_SIZE = 10;
    private static final long LIVE_SKEW_MS = 5_000L;

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("Usage: DataGenerator <bootstrap-servers> <batch|live> <base_ts_ms> [seed]");
            System.exit(2);
        }
        String bootstrapServers = args[0];
        String mode = args[1];
        long baseTs = Long.parseLong(args[2]);
        long seed = args.length > 3 ? Long.parseLong(args[3]) : 42L;

        Properties props = new Properties();
        props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        props.put(ProducerConfig.ACKS_CONFIG, "all");
        props.put(ProducerConfig.ENABLE_IDEMPOTENCE_CONFIG, "true");

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(props)) {
            if ("batch".equals(mode)) {
                runBatch(producer, baseTs, seed);
            } else if ("live".equals(mode)) {
                runLive(producer, baseTs, seed);
            } else {
                System.err.println("Unknown mode: " + mode);
                System.exit(2);
            }
        }
    }

    private static void runBatch(KafkaProducer<String, String> producer, long baseTs, long seed) {
        int matched = 0;
        int unmatched = 0;
        for (int i = 1; i <= BATCH_ORDERS; i++) {
            long orderTs = baseTs + i * 1000L;
            sendOrder(producer, i, orderTs, seed);
            if (i % 7 == 0) {
                sendPayment(producer, i, orderTs + UNMATCHED_DELAY_MS, seed);
                unmatched++;
            } else {
                sendPayment(producer, i, orderTs + MATCH_DELAY_MS, seed);
                matched++;
            }
        }
        producer.flush();
        log.info("Batch complete: {} orders, {} matched payments, {} unmatched (late) payments",
                BATCH_ORDERS, matched, unmatched);
    }

    private static void runLive(KafkaProducer<String, String> producer, long baseTs, long seed)
            throws InterruptedException {
        int i = 0;
        int round = 0;
        while (true) {
            round++;
            int start = i + 1;
            int end = i + LIVE_ROUND_SIZE;
            for (int n = start; n <= end; n++) {
                sendOrder(producer, n, baseTs + n * 1000L, seed);
            }
            producer.flush();
            log.info("Round {}: produced orders {}..{}, sleeping {} ms before payments (skew)",
                    round, start, end, LIVE_SKEW_MS);
            Thread.sleep(LIVE_SKEW_MS);
            for (int n = start; n <= end; n++) {
                sendPayment(producer, n, baseTs + n * 1000L + MATCH_DELAY_MS, seed);
            }
            producer.flush();
            log.info("Round {}: produced payments {}..{}", round, start, end);
            i = end;
        }
    }

    private static void sendOrder(KafkaProducer<String, String> producer, int i, long eventTime, long seed) {
        String orderId = String.format("ORD-%04d", i);
        String customerId = "CUST-" + (1 + (i % CUSTOMERS));
        long amount = amountFor(i, seed);
        String value = String.format(
                "{\"type\":\"order\",\"order_id\":\"%s\",\"customer_id\":\"%s\",\"amount\":%d,\"event_time\":%d}",
                orderId, customerId, amount, eventTime);
        producer.send(new ProducerRecord<>(DemoStatefulJoin.ORDERS_TOPIC, null, eventTime, orderId, value));
    }

    private static void sendPayment(KafkaProducer<String, String> producer, int i, long eventTime, long seed) {
        String orderId = String.format("ORD-%04d", i);
        String paymentId = String.format("PAY-%04d", i);
        long amount = amountFor(i, seed);
        String value = String.format(
                "{\"type\":\"payment\",\"payment_id\":\"%s\",\"order_id\":\"%s\",\"amount\":%d,\"event_time\":%d}",
                paymentId, orderId, amount, eventTime);
        producer.send(new ProducerRecord<>(DemoStatefulJoin.PAYMENTS_TOPIC, null, eventTime, orderId, value));
    }

    /** Deterministic pseudo-random amount in 100..999, pure function of (i, seed). */
    private static long amountFor(int i, long seed) {
        return 100 + Math.floorMod(i * 7919L + seed * 104729L, 900L);
    }
}
