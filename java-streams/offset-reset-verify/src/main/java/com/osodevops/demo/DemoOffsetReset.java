package com.osodevops.demo;

import org.apache.kafka.clients.consumer.*;
import org.apache.kafka.common.TopicPartition;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.*;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Offset Reset Verification Demo
 *
 * Demonstrates bulk offset reset correctness:
 * - Consumes from 'payments' topic up to a target count
 * - Records all processed offsets to a file
 * - After offset reset, verifies exact re-reading of specified records
 *
 * Usage:
 *   mvn clean package
 *   java -jar target/offset-reset-verify-demo.jar [bootstrap-servers] [target-count]
 *
 * Or with Maven:
 *   mvn exec:java -Dexec.args="localhost:9092 50"
 */
public class DemoOffsetReset {

    private static final Logger log = LoggerFactory.getLogger(DemoOffsetReset.class);
    private static final String TOPIC = "payments";
    private static final String GROUP_ID = "payments-processor";
    private static final String OFFSETS_FILE = "processed-offsets.txt";

    private static final AtomicBoolean running = new AtomicBoolean(true);

    public static void main(String[] args) throws Exception {
        String bootstrapServers = args.length > 0 ? args[0] : "localhost:9092";
        int targetCount = args.length > 1 ? Integer.parseInt(args[1]) : 50;

        log.info("==============================================");
        log.info("   Offset Reset Verification Demo");
        log.info("==============================================");
        log.info("Bootstrap servers: {}", bootstrapServers);
        log.info("Topic: {}", TOPIC);
        log.info("Consumer group: {}", GROUP_ID);
        log.info("Target count: {}", targetCount);
        log.info("");

        // Setup shutdown hook
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            log.info("Shutdown requested...");
            running.set(false);
        }));

        // Phase 1: Initial consumption
        log.info("Phase 1: Initial consumption up to {} messages", targetCount);
        log.info("─".repeat(50));

        List<ProcessedRecord> processedRecords = consumeMessages(bootstrapServers, targetCount);

        if (processedRecords.isEmpty()) {
            log.warn("No messages consumed. Please produce messages first:");
            log.warn("  docker compose --profile tools run --rm kafka-cli bash -c '");
            log.warn("    for i in $(seq 1 100); do");
            log.warn("      echo \"{\\\"payment_id\\\": \\\"PAY-$i\\\", \\\"amount\\\": $((RANDOM % 1000))}\"");
            log.warn("    done | kafka-console-producer.sh --bootstrap-server kafka-broker-1:9092 --topic payments'");
            return;
        }

        // Save processed offsets
        saveProcessedOffsets(processedRecords);

        log.info("");
        log.info("Phase 1 Complete!");
        log.info("─".repeat(50));
        log.info("Processed {} messages", processedRecords.size());
        log.info("Last offset per partition:");
        getLastOffsetPerPartition(processedRecords).forEach((partition, offset) ->
            log.info("  Partition {}: offset {}", partition, offset));
        log.info("");
        log.info("Offsets saved to: {}", OFFSETS_FILE);
        log.info("");
        log.info("==============================================");
        log.info("   Next Steps (Manual)");
        log.info("==============================================");
        log.info("");
        log.info("1. Perform bulk offset reset (e.g., reset to 20 messages back):");
        log.info("   docker compose --profile tools run --rm kafka-backup \\");
        log.info("     offset-reset execute --path s3://kafka-backups/demo \\");
        log.info("     --backup-id <BACKUP_ID> --groups {} \\", GROUP_ID);
        log.info("     --bootstrap-servers kafka-broker-1:9092");
        log.info("");
        log.info("   Or use kafka-consumer-groups:");
        log.info("   docker compose --profile tools run --rm kafka-cli bash -c '");
        log.info("     kafka-consumer-groups.sh --bootstrap-server kafka-broker-1:9092 \\");
        log.info("       --group {} --topic {} \\", GROUP_ID, TOPIC);
        log.info("       --reset-offsets --shift-by -20 --execute'");
        log.info("");
        log.info("2. Run this app again to verify re-consumption");
        log.info("");
        log.info("3. Compare {} with new output", OFFSETS_FILE);
    }

    private static List<ProcessedRecord> consumeMessages(String bootstrapServers, int targetCount) {
        Properties props = new Properties();
        props.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, bootstrapServers);
        props.put(ConsumerConfig.GROUP_ID_CONFIG, GROUP_ID);
        props.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        props.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "true");
        props.put(ConsumerConfig.AUTO_COMMIT_INTERVAL_MS_CONFIG, "1000");

        List<ProcessedRecord> processed = new ArrayList<>();

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(props)) {
            consumer.subscribe(Collections.singletonList(TOPIC));

            int emptyPollCount = 0;
            int maxEmptyPolls = 10;

            while (running.get() && processed.size() < targetCount && emptyPollCount < maxEmptyPolls) {
                ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(1000));

                if (records.isEmpty()) {
                    emptyPollCount++;
                    continue;
                }

                emptyPollCount = 0;

                for (ConsumerRecord<String, String> record : records) {
                    if (processed.size() >= targetCount) {
                        break;
                    }

                    ProcessedRecord pr = new ProcessedRecord(
                        record.partition(),
                        record.offset(),
                        record.key(),
                        record.value(),
                        record.timestamp()
                    );

                    processed.add(pr);

                    log.info("Processed: partition={}, offset={}, value={}",
                        record.partition(),
                        record.offset(),
                        truncate(record.value(), 50));
                }
            }

            // Commit offsets
            consumer.commitSync();
            log.info("Committed offsets");
        }

        return processed;
    }

    private static void saveProcessedOffsets(List<ProcessedRecord> records) throws IOException {
        try (PrintWriter writer = new PrintWriter(new FileWriter(OFFSETS_FILE))) {
            writer.println("# Processed offsets - " + new Date());
            writer.println("# Format: partition,offset,timestamp,value_preview");
            writer.println();

            for (ProcessedRecord record : records) {
                writer.printf("%d,%d,%d,%s%n",
                    record.partition,
                    record.offset,
                    record.timestamp,
                    truncate(record.value, 30).replace(",", ";"));
            }
        }
    }

    private static Map<Integer, Long> getLastOffsetPerPartition(List<ProcessedRecord> records) {
        Map<Integer, Long> lastOffsets = new HashMap<>();
        for (ProcessedRecord record : records) {
            lastOffsets.merge(record.partition, record.offset, Math::max);
        }
        return lastOffsets;
    }

    private static String truncate(String value, int maxLength) {
        if (value == null) return "null";
        if (value.length() <= maxLength) return value;
        return value.substring(0, maxLength - 3) + "...";
    }

    /**
     * Record class to store processed message info
     */
    static class ProcessedRecord {
        final int partition;
        final long offset;
        final String key;
        final String value;
        final long timestamp;

        ProcessedRecord(int partition, long offset, String key, String value, long timestamp) {
            this.partition = partition;
            this.offset = offset;
            this.key = key;
            this.value = value;
            this.timestamp = timestamp;
        }
    }
}
