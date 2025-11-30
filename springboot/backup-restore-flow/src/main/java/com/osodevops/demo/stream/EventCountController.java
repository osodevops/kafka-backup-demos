package com.osodevops.demo.stream;

import org.apache.kafka.streams.KafkaStreams;
import org.apache.kafka.streams.StoreQueryParameters;
import org.apache.kafka.streams.state.QueryableStoreTypes;
import org.apache.kafka.streams.state.ReadOnlyKeyValueStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.config.StreamsBuilderFactoryBean;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.HashMap;
import java.util.Map;

/**
 * REST controller to query event counts from the state store.
 *
 * Endpoints:
 *   GET /counts       - Get all event counts
 *   GET /counts/{key} - Get count for specific key
 */
@RestController
@RequestMapping("/counts")
public class EventCountController {

    private static final Logger log = LoggerFactory.getLogger(EventCountController.class);

    private final StreamsBuilderFactoryBean factoryBean;
    private final String storeName;

    public EventCountController(
            StreamsBuilderFactoryBean factoryBean,
            @Value("${app.store-name:events-count-store}") String storeName) {
        this.factoryBean = factoryBean;
        this.storeName = storeName;
    }

    @GetMapping
    public Map<String, Long> getAllCounts() {
        Map<String, Long> counts = new HashMap<>();

        try {
            ReadOnlyKeyValueStore<String, Long> store = getStore();
            if (store != null) {
                store.all().forEachRemaining(kv -> counts.put(kv.key, kv.value));
            }
        } catch (Exception e) {
            log.warn("Could not query state store: {}", e.getMessage());
        }

        return counts;
    }

    @GetMapping("/{key}")
    public Map<String, Object> getCount(@PathVariable String key) {
        Map<String, Object> result = new HashMap<>();
        result.put("key", key);

        try {
            ReadOnlyKeyValueStore<String, Long> store = getStore();
            if (store != null) {
                Long count = store.get(key);
                result.put("count", count != null ? count : 0);
            } else {
                result.put("count", 0);
                result.put("error", "State store not available");
            }
        } catch (Exception e) {
            result.put("count", 0);
            result.put("error", e.getMessage());
        }

        return result;
    }

    private ReadOnlyKeyValueStore<String, Long> getStore() {
        KafkaStreams kafkaStreams = factoryBean.getKafkaStreams();
        if (kafkaStreams == null || kafkaStreams.state() != KafkaStreams.State.RUNNING) {
            return null;
        }

        return kafkaStreams.store(
            StoreQueryParameters.fromNameAndType(storeName, QueryableStoreTypes.keyValueStore()));
    }
}
