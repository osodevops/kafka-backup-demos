package com.osodevops.demo.consumer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.osodevops.demo.model.OrderEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Order event consumer.
 *
 * Consumes order events, validates them, and tracks processed IDs.
 */
@Component
@RestController
@RequestMapping("/consumer")
@ConditionalOnProperty(name = "app.consumer.enabled", havingValue = "true", matchIfMissing = true)
public class OrderConsumer {

    private static final Logger log = LoggerFactory.getLogger(OrderConsumer.class);

    private final ObjectMapper objectMapper = new ObjectMapper();

    // Tracking
    private final Set<String> processedIds = ConcurrentHashMap.newKeySet();
    private final Set<String> invalidIds = ConcurrentHashMap.newKeySet();
    private final AtomicLong totalProcessed = new AtomicLong(0);
    private final AtomicLong totalInvalid = new AtomicLong(0);

    // Recent orders for display
    private final Deque<OrderEvent> recentOrders = new LinkedList<>();
    private static final int MAX_RECENT = 20;

    @KafkaListener(topics = "${app.topic:orders}", groupId = "${spring.kafka.consumer.group-id:demo-consumer}")
    public void consume(String message) {
        totalProcessed.incrementAndGet();

        try {
            OrderEvent event = objectMapper.readValue(message, OrderEvent.class);

            if (event.isValid()) {
                processedIds.add(event.getOrderId());
                log.info("Processed valid order: {}", event.getOrderId());
            } else {
                invalidIds.add(event.getOrderId());
                totalInvalid.incrementAndGet();
                log.error("INVALID ORDER DETECTED: {} (amount: {})",
                    event.getOrderId(), event.getAmount());
            }

            // Track recent orders
            synchronized (recentOrders) {
                recentOrders.addFirst(event);
                while (recentOrders.size() > MAX_RECENT) {
                    recentOrders.removeLast();
                }
            }

        } catch (Exception e) {
            log.error("Failed to parse order: {}", e.getMessage());
        }
    }

    // REST Endpoints

    @GetMapping("/status")
    public Map<String, Object> getStatus() {
        return Map.of(
            "totalProcessed", totalProcessed.get(),
            "validOrders", processedIds.size(),
            "invalidOrders", invalidIds.size(),
            "invalidRate", totalProcessed.get() > 0
                ? String.format("%.2f%%", (double) invalidIds.size() / totalProcessed.get() * 100)
                : "0%"
        );
    }

    @GetMapping("/processed")
    public Map<String, Object> getProcessedIds() {
        return Map.of(
            "count", processedIds.size(),
            "ids", new ArrayList<>(processedIds).subList(0, Math.min(100, processedIds.size()))
        );
    }

    @GetMapping("/invalid")
    public Map<String, Object> getInvalidIds() {
        return Map.of(
            "count", invalidIds.size(),
            "ids", new ArrayList<>(invalidIds)
        );
    }

    @GetMapping("/recent")
    public List<Map<String, Object>> getRecentOrders() {
        List<Map<String, Object>> result = new ArrayList<>();
        synchronized (recentOrders) {
            for (OrderEvent event : recentOrders) {
                result.add(Map.of(
                    "orderId", event.getOrderId(),
                    "amount", event.getAmount(),
                    "status", event.getStatus(),
                    "valid", event.isValid()
                ));
            }
        }
        return result;
    }

    @GetMapping("/clear")
    public Map<String, String> clearTracking() {
        processedIds.clear();
        invalidIds.clear();
        totalProcessed.set(0);
        totalInvalid.set(0);
        synchronized (recentOrders) {
            recentOrders.clear();
        }
        log.info("Cleared all tracking data");
        return Map.of("status", "cleared");
    }
}
