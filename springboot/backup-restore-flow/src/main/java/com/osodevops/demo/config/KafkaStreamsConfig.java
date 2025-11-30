package com.osodevops.demo.config;

import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.kstream.KStream;
import org.apache.kafka.streams.kstream.KTable;
import org.apache.kafka.streams.kstream.Materialized;
import org.apache.kafka.streams.kstream.Produced;
import org.apache.kafka.streams.state.KeyValueStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.kafka.annotation.EnableKafkaStreams;

/**
 * Kafka Streams topology configuration.
 *
 * Topology:
 *   events -> groupByKey -> count -> events_agg
 *
 * The count is materialized to a state store for query access.
 */
@Configuration
public class KafkaStreamsConfig {

    private static final Logger log = LoggerFactory.getLogger(KafkaStreamsConfig.class);

    @Value("${app.topics.input:events}")
    private String inputTopic;

    @Value("${app.topics.output:events_agg}")
    private String outputTopic;

    @Value("${app.store-name:events-count-store}")
    private String storeName;

    @Bean
    public KStream<String, String> eventsStream(StreamsBuilder builder) {
        log.info("Building Kafka Streams topology:");
        log.info("  Input topic: {}", inputTopic);
        log.info("  Output topic: {}", outputTopic);
        log.info("  State store: {}", storeName);

        // Source stream from events topic
        KStream<String, String> eventsStream = builder.stream(inputTopic);

        // Log incoming events
        eventsStream.peek((key, value) ->
            log.debug("Received event: key={}, value={}", key, value));

        // Group by key and count
        KTable<String, Long> eventCounts = eventsStream
            .groupByKey()
            .count(Materialized.<String, Long, KeyValueStore<org.apache.kafka.common.utils.Bytes, byte[]>>as(storeName)
                .withKeySerde(Serdes.String())
                .withValueSerde(Serdes.Long()));

        // Log and output counts
        eventCounts.toStream()
            .peek((key, count) ->
                log.info("Event count updated: key={}, count={}", key, count))
            .mapValues(Object::toString)
            .to(outputTopic, Produced.with(Serdes.String(), Serdes.String()));

        return eventsStream;
    }
}
