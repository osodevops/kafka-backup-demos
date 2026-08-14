package com.osodevops.demo;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.streams.processor.TimestampExtractor;

/**
 * Extracts the event time from the {@code event_time} field of the JSON payload.
 *
 * Using payload event time (rather than the broker record timestamp) makes the
 * windowed join semantics independent of whether the backup/restore path
 * preserves record timestamps. Record-timestamp preservation is still verified
 * separately by the demo scripts, because real applications commonly rely on
 * CreateTime.
 */
public class EventTimeExtractor implements TimestampExtractor {

    private static final ObjectMapper mapper = new ObjectMapper();

    @Override
    public long extract(ConsumerRecord<Object, Object> record, long partitionTime) {
        Object value = record.value();
        if (value instanceof String s) {
            try {
                JsonNode node = mapper.readTree(s);
                JsonNode ts = node.get("event_time");
                if (ts != null && ts.isNumber()) {
                    return ts.asLong();
                }
            } catch (Exception ignored) {
                // fall through to record timestamp
            }
        }
        return record.timestamp() >= 0 ? record.timestamp() : partitionTime;
    }
}
