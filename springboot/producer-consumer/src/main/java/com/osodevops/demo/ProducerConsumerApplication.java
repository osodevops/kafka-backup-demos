package com.osodevops.demo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * Spring Boot Producer/Consumer PITR Demo
 *
 * Demonstrates PITR with classic microservice pattern:
 * - Producer: Generates order events with timestamps and IDs
 * - Consumer: Processes orders, validates amounts, logs IDs
 *
 * Modes:
 *   Both:     java -jar app.jar (default)
 *   Producer: java -jar app.jar --app.consumer.enabled=false --server.port=8081
 *   Consumer: java -jar app.jar --app.producer.enabled=false --server.port=8082
 */
@SpringBootApplication
@EnableScheduling
public class ProducerConsumerApplication {

    public static void main(String[] args) {
        System.out.println("==============================================");
        System.out.println("   Spring Boot Producer/Consumer PITR Demo");
        System.out.println("==============================================");
        System.out.println();

        SpringApplication.run(ProducerConsumerApplication.class, args);
    }
}
