package dev.notchi.backend.stats;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

class DurationStatsTest {

    @Test
    @DisplayName("edge: not enough history → enough = false")
    void notEnough() {
        DurationStats s = new DurationStats(null, new Random(1));
        Map<String, Object> m = s.summary("crm");
        assertEquals(false, m.get("enough"));
        s.record("crm", 10);
        assertEquals(1, s.summary("crm").get("count"));
        assertEquals(false, s.summary("crm").get("enough"));
    }

    @Test
    @DisplayName("percentiles for a tab with enough runs")
    void percentiles() {
        DurationStats s = new DurationStats(null, new Random(1));
        for (int i = 1; i <= 100; i++) s.record("CRM", i);       // keys are case-insensitive
        Map<String, Object> m = s.summary("crm");
        assertEquals(true, m.get("enough"));
        assertEquals("crm", m.get("scope"));
        assertEquals(50.0, m.get("p50"));
        assertEquals(90.0, m.get("p90"));
        assertEquals(99.0, m.get("p99"));
        assertEquals(1.0, m.get("min"));
        assertEquals(100.0, m.get("max"));
    }

    @Test
    @DisplayName("a new tab borrows the all-tabs history until it has 5 runs of its own")
    void fallsBackToAll() {
        DurationStats s = new DurationStats(null, new Random(1));
        for (int i = 0; i < 10; i++) s.record("crm", 100);
        s.record("docs", 5);
        assertEquals("all tabs", s.summary("docs").get("scope"));
        for (int i = 0; i < 4; i++) s.record("docs", 5);
        assertEquals("docs", s.summary("docs").get("scope"));
        assertEquals(5.0, s.summary("docs").get("p50"));
    }

    @Test
    @DisplayName("history is saved to CSV and reloaded; CSV import validates every line")
    void persistenceAndImport(@TempDir Path dir) throws Exception {
        Path f = dir.resolve("durations.csv");
        DurationStats s = new DurationStats(f, new Random(1));
        assertEquals(3, s.importCsv(List.of("key,seconds", "crm,10", "", "1700000000000,crm,20", "crm,30")));
        assertEquals(3, Files.readAllLines(f).size());
        DurationStats reloaded = new DurationStats(f, new Random(1));
        assertEquals(3, reloaded.summary("crm").get("count"));
        IllegalArgumentException bad = assertThrows(IllegalArgumentException.class,
                () -> s.importCsv(List.of("crm,10", "crm,abc")));
        assertTrue(bad.getMessage().startsWith("line 2"));
        // A broken first line is an error, not a header to skip.
        assertTrue(assertThrows(IllegalArgumentException.class,
                () -> s.importCsv(List.of("crm,abc", "crm,5"))).getMessage().startsWith("line 1"));
        assertEquals(3, s.summary("crm").get("count"), "a rejected import adds nothing");
    }

    @Test
    @DisplayName("invalid durations and keys are rejected")
    void validation() {
        DurationStats s = new DurationStats(null, new Random(1));
        assertThrows(IllegalArgumentException.class, () -> s.record("crm", 0));
        assertThrows(IllegalArgumentException.class, () -> s.record("crm", -5));
        assertThrows(IllegalArgumentException.class, () -> s.record("crm", Double.NaN));
        assertThrows(IllegalArgumentException.class, () -> s.record("crm", 8 * 24 * 3600));
        assertThrows(IllegalArgumentException.class, () -> s.record(" ", 5));
        assertThrows(IllegalArgumentException.class, () -> s.record("x".repeat(101), 5));
    }
}
