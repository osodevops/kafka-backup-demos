package com.osodevops.demo.producer;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.osodevops.demo.model.OrderEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.Random;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Order event producer.
 *
 * Produces order events at a configurable rate.
 * Also exposes REST endpoints for manual event injection.
 */
@Component
@RestController
@RequestMapping("/producer")
@ConditionalOnProperty(name = "app.producer.enabled", havingValue = "true", matchIfMissing = true)
public class OrderProducer {

    private static final Logger log = LoggerFactory.getLogger(OrderProducer.class);

    private final KafkaTemplate<String, String> kafkaTemplate;
    private final ObjectMapper objectMapper;
    private final String topic;
    private final Random random = new Random();

    private final AtomicLong orderCounter = new AtomicLong(0);
    private boolean producing = false;

    public OrderProducer(
            KafkaTemplate<String, String> kafkaTemplate,
            @Value("${app.topic:orders}") String topic) {
        this.kafkaTemplate = kafkaTemplate;
        this.topic = topic;
        this.objectMapper = new ObjectMapper();
    }

    /**
     * Scheduled production of order events.
     */
    @Scheduled(fixedRateString = "${app.producer.rate-ms:1000}")
    public void produceOrder() {
        if (!producing) return;

        long id = orderCounter.incrementAndGet();
        String orderId = String.format("ORD-%05d", id);
        String customerId = String.format("CUST-%03d", random.nextInt(100));
        double amount = 100 + random.nextDouble() * 900;

        OrderEvent event = new OrderEvent(orderId, customerId, amount);
        sendEvent(event);
    }

    /**
     * Send an order event to Kafka.
     */
    private void sendEvent(OrderEvent event) {
        try {
            String json = objectMapper.writeValueAsString(event);
            kafkaTemplate.send(topic, event.getOrderId(), json);
            log.info("Produced: {}", event);
        } catch (Exception e) {
            log.error("Failed to produce event: {}", e.getMessage());
        }
    }

    // REST Endpoints

    @PostMapping("/start")
    public Map<String, Object> startProducing() {
        producing = true;
        log.info("Started producing orders");
        return Map.of("status", "started", "producing", true);
    }

    @PostMapping("/stop")
    public Map<String, Object> stopProducing() {
        producing = false;
        log.info("Stopped producing orders");
        return Map.of("status", "stopped", "producing", false);
    }

    @GetMapping("/status")
    public Map<String, Object> getStatus() {
        return Map.of(
            "producing", producing,
            "totalProduced", orderCounter.get()
        );
    }

    /**
     * Manually inject a single order.
     */
    @PostMapping("/order")
    public Map<String, Object> produceManualOrder(@RequestBody(required = false) Map<String, Object> body) {
        long id = orderCounter.incrementAndGet();
        String orderId = body != null && body.containsKey("order_id")
            ? (String) body.get("order_id")
            : String.format("ORD-%05d", id);

        double amount = body != null && body.containsKey("amount")
            ? ((Number) body.get("amount")).doubleValue()
            : 100 + random.nextDouble() * 900;

        String customerId = body != null && body.containsKey("customer_id")
            ? (String) body.get("customer_id")
            : String.format("CUST-%03d", random.nextInt(100));

        OrderEvent event = new OrderEvent(orderId, customerId, amount);
        sendEvent(event);

        return Map.of(
            "status", "sent",
            "order", event.toString()
        );
    }

    /**
     * Inject bad orders (negative amounts) for PITR testing.
     */
    @PostMapping("/inject-bad")
    public Map<String, Object> injectBadOrders(@RequestParam(defaultValue = "10") int count) {
        log.warn("Injecting {} bad orders!", count);

        for (int i = 0; i < count; i++) {
            long id = orderCounter.incrementAndGet();
            String orderId = String.format("BAD-%05d", id);
            OrderEvent event = new OrderEvent(orderId, "INVALID", -999);
            event.setStatus("CORRUPTED");
            sendEvent(event);
        }

        return Map.of(
            "status", "injected",
            "count", count,
            "warning", "Bad orders injected - use PITR to recover!"
        );
    }
}
