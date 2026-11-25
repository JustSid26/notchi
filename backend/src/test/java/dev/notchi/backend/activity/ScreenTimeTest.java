package dev.notchi.backend.activity;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

class ScreenTimeTest {

    private static final int TZ = 330;   // India, UTC+5:30
    private static final ZoneOffset IST = ZoneOffset.ofHoursMinutes(5, 30);
    private final AtomicLong now = new AtomicLong(at(2026, 11, 25, 23, 0));

    static long at(int y, int mo, int d, int h, int mi) {
        return LocalDateTime.of(y, mo, d, h, mi).toInstant(IST).toEpochMilli();
    }

    private static ScreenTime.Span span(String app, long start, long end) {
        return new ScreenTime.Span(app, app.toUpperCase(), start, end);
    }

    @Test
    @DisplayName("edge: no data gives zeros and no busiest hour")
    void empty() {
        Map<String, Object> s = new ScreenTime(null, now::get).today(TZ);
        assertEquals(0L, s.get("totalSeconds"));
        assertNull(s.get("busiestHour"));
        assertEquals(List.of(), s.get("apps"));
    }

    @Test
    @DisplayName("totals, per-app time, hourly bars and busiest hour")
    void summary() {
        ScreenTime st = new ScreenTime(null, now::get);
        st.add(List.of(
                span("figma", at(2026, 11, 25, 9, 0), at(2026, 11, 25, 10, 0)),          // 60 min
                span("slack", at(2026, 11, 25, 10, 0), at(2026, 11, 25, 10, 30)),        // 30 min
                span("figma", at(2026, 11, 25, 14, 15), at(2026, 11, 25, 14, 45))), TZ); // 30 min
        Map<String, Object> s = st.today(TZ);
        assertEquals(7200L, s.get("totalSeconds"));
        assertEquals(9, s.get("busiestHour"));
        @SuppressWarnings("unchecked")
        List<Map<String, Object>> apps = (List<Map<String, Object>>) s.get("apps");
        assertEquals("figma", apps.get(0).get("app"));
        assertEquals(5400L, apps.get(0).get("seconds"));
        assertEquals(1800L, ((List<?>) s.get("hourly")).get(14));
        assertEquals(1800L, st.range("figma", at(2026, 11, 25, 14, 0), at(2026, 11, 25, 15, 0), TZ));
        assertEquals(3600L, st.range(null, at(2026, 11, 25, 9, 30), at(2026, 11, 25, 10, 30), TZ));
    }

    @Test
    @DisplayName("re-sent or overlapping spans are never counted twice")
    void noDoubleCounting() {
        ScreenTime st = new ScreenTime(null, now::get);
        ScreenTime.Span s = span("xcode", at(2026, 11, 25, 9, 0), at(2026, 11, 25, 9, 10));
        assertEquals(600, st.add(List.of(s), TZ));
        assertEquals(0, st.add(List.of(s), TZ));
        assertEquals(300, st.add(List.of(span("xcode", at(2026, 11, 25, 9, 5), at(2026, 11, 25, 9, 15))), TZ));
        assertEquals(900L, st.today(TZ).get("totalSeconds"));
    }

    @Test
    @DisplayName("boundary: a span across midnight is split between two days; longest focus joins short gaps")
    void midnightAndFocus() {
        ScreenTime st = new ScreenTime(null, now::get);
        st.add(List.of(span("iterm", at(2026, 11, 24, 23, 50), at(2026, 11, 25, 0, 20))), TZ);
        assertEquals(1200L, st.today(TZ).get("totalSeconds"));          // 00:00–00:20 today
        assertEquals(600L, st.summary(java.time.LocalDate.of(2026, 11, 24)).get("totalSeconds"));
        st.add(List.of(
                span("xcode", at(2026, 11, 25, 9, 0), at(2026, 11, 25, 9, 30)),
                span("xcode", at(2026, 11, 25, 9, 30, 30), at(2026, 11, 25, 10, 0)),   // 30 s gap: same session
                span("mail", at(2026, 11, 25, 10, 0), at(2026, 11, 25, 10, 5))), TZ);
        @SuppressWarnings("unchecked")
        Map<String, Object> focus = (Map<String, Object>) st.today(TZ).get("longestFocus");
        assertEquals("xcode", focus.get("app"));
        assertEquals(3600L, focus.get("seconds"));
    }

    @Test
    @DisplayName("invalid spans are rejected; history survives a restart")
    void validationAndPersistence(@TempDir Path dir) {
        ScreenTime st = new ScreenTime(dir.resolve("st.csv"), now::get);
        long t = at(2026, 11, 25, 9, 0);
        assertThrows(IllegalArgumentException.class, () -> st.add(List.of(span("x", t, t)), TZ));
        assertThrows(IllegalArgumentException.class, () -> st.add(List.of(span("x", t, t + 13 * 3600_000L)), TZ));
        assertThrows(IllegalArgumentException.class, () -> st.add(List.of(span("x", now.get() + 120_000, now.get() + 180_000)), TZ));
        assertThrows(IllegalArgumentException.class, () -> st.add(List.of(new ScreenTime.Span(" ", "n", t, t + 1000)), TZ));
        assertThrows(IllegalArgumentException.class, () -> st.today(5000));
        st.add(List.of(span("figma", t, t + 600_000)), TZ);
        ScreenTime reloaded = new ScreenTime(dir.resolve("st.csv"), now::get);
        assertEquals(600L, reloaded.today(TZ).get("totalSeconds"));
    }

    @Test
    @DisplayName("a batch with one bad span changes nothing; a damaged history file still loads")
    void atomicBatchAndTornFile(@TempDir Path dir) throws Exception {
        ScreenTime st = new ScreenTime(dir.resolve("st.csv"), now::get);
        long t = at(2026, 11, 25, 9, 0);
        assertThrows(IllegalArgumentException.class, () -> st.add(List.of(
                span("good", t, t + 600_000), new ScreenTime.Span("bad", "x".repeat(121), t + 600_000, t + 700_000)), TZ));
        assertEquals(0L, st.today(TZ).get("totalSeconds"));
        assertEquals(600, st.add(List.of(span("good", t, t + 600_000)), TZ));   // the retry still counts
        java.nio.file.Files.write(dir.resolve("st.csv"), new byte[]{'1', ',', (byte) 0xC3, (byte) 0x28, '\n'},
                java.nio.file.StandardOpenOption.APPEND);                         // a torn, invalid UTF-8 line
        assertEquals(600L, new ScreenTime(dir.resolve("st.csv"), now::get).today(TZ).get("totalSeconds"));
    }

    static long at(int y, int mo, int d, int h, int mi, int s) {
        return LocalDateTime.of(y, mo, d, h, mi, s).toInstant(IST).toEpochMilli();
    }
}
