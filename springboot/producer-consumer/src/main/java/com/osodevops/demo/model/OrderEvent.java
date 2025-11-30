package com.osodevops.demo.model;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.time.Instant;

/**
 * Order event model.
 */
public class OrderEvent {

    @JsonProperty("order_id")
    private String orderId;

    @JsonProperty("customer_id")
    private String customerId;

    @JsonProperty("amount")
    private double amount;

    @JsonProperty("timestamp")
    private String timestamp;

    @JsonProperty("status")
    private String status;

    public OrderEvent() {}

    public OrderEvent(String orderId, String customerId, double amount) {
        this.orderId = orderId;
        this.customerId = customerId;
        this.amount = amount;
        this.timestamp = Instant.now().toString();
        this.status = amount >= 0 ? "valid" : "invalid";
    }

    // Getters and setters
    public String getOrderId() { return orderId; }
    public void setOrderId(String orderId) { this.orderId = orderId; }

    public String getCustomerId() { return customerId; }
    public void setCustomerId(String customerId) { this.customerId = customerId; }

    public double getAmount() { return amount; }
    public void setAmount(double amount) { this.amount = amount; }

    public String getTimestamp() { return timestamp; }
    public void setTimestamp(String timestamp) { this.timestamp = timestamp; }

    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }

    public boolean isValid() {
        return amount >= 0 && !"invalid".equals(status);
    }

    @Override
    public String toString() {
        return String.format("OrderEvent{orderId='%s', amount=%.2f, status='%s'}",
            orderId, amount, status);
    }
}
