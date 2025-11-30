package com.osodevops.demo;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.kafka.annotation.EnableKafkaStreams;

/**
 * Spring Boot Kafka Streams Demo Application
 *
 * Demonstrates backup/restore with Spring Kafka Streams:
 * - Consumes events from 'events' topic
 * - Aggregates event counts by key
 * - Writes aggregated counts to 'events_agg' topic
 *
 * Usage:
 *   mvn spring-boot:run
 *   or
 *   java -jar target/springboot-backup-restore-demo-1.0-SNAPSHOT.jar
 */
@SpringBootApplication
@EnableKafkaStreams
public class BackupRestoreApplication {

    public static void main(String[] args) {
        System.out.println("==============================================");
        System.out.println("   Spring Boot Backup/Restore Demo");
        System.out.println("==============================================");
        System.out.println();

        SpringApplication.run(BackupRestoreApplication.class, args);
    }
}
