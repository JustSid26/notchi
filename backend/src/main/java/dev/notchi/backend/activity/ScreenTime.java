package dev.notchi.backend.activity;

import dev.notchi.backend.algo.tree.SegmentTree;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.function.LongSupplier;

/**
 * Screen time: which app was in front, minute by minute.
 *
 * <p>The Mac app reports spans ("Figma was frontmost from 14:02:10 to 14:31:55"). Each span
 * is split into minutes and added to two {@link SegmentTree}s for that day (1,440 leaves,
 * one per minute, value = seconds in front): one for the app, one for all apps together.
 * Then every question is a range query:
 * <ul>
 *   <li>time in an app today / between two times → range sum, O(log n)</li>
 *   <li>the hourly bars → 24 range sums; the busiest hour → the largest of them</li>
 *   <li>the most active minute → argMax over the day, O(log n)</li>
 *   <li>Workspaces: which apps were used in each 15-minute block → per-app range sums</li>
 * </ul>
 * Spans are stored in a CSV so the trees can be rebuilt after a restart. Days older than
 * {@value #KEEP_DAYS} are dropped.
 */
public final class ScreenTime {

    public static final int MINUTES = 1440;
    public static final int KEEP_DAYS = 35;
    public static final long MAX_SPAN_MS = 12L * 3600 * 1000;

    /** One stretch of time with one app in front. Times are epoch millis (UTC). */
    public record Span(String app, String name, long start, long end) {}

    static final class Day {
        final Map<String, SegmentTree> perApp = new HashMap<>();
        final SegmentTree all = new SegmentTree(MINUTES);
        final List<Span> spans = new ArrayList<>();

        SegmentTree tree(String app) { return perApp.computeIfAbsent(app, a -> new SegmentTree(MINUTES)); }
    }

    private final TreeMap<LocalDate, Day> days = new TreeMap<>();
    private final Map<String, String> names = new HashMap<>();
    private final Path file;
    private final LongSupplier clock;
    private long lastEnd;   // spans never overlap: a re-sent span only counts from here on

    public ScreenTime(Path file, LongSupplier clock) {
        this.file = file;
        this.clock = clock;
        if (file != null && Files.exists(file)) load();
    }

    /** Adds spans (validated, clamped so nothing is counted twice). Returns seconds added. */
    public synchronized long add(List<Span> spans, int utcOffsetMinutes) {
        ZoneOffset zone = zone(utcOffsetMinutes);
        long now = clock.getAsLong();
        // All or nothing: check every span before anything changes.
        for (Span s : spans) validate(s, now);
        List<Span> accepted = new ArrayList<>();
        List<String> lines = new ArrayList<>();
        long high = lastEnd;
        for (Span s : spans) {
            long start = Math.max(s.start(), high);
            if (s.end() <= start) continue;
            accepted.add(new Span(s.app(), s.name(), start, s.end()));
            lines.add(start + "," + s.end() + "," + utcOffsetMinutes + "," + csv(s.app()) + "," + csv(s.name()));
            high = s.end();
        }
        append(lines);          // on disk first: if this fails, memory is unchanged and the app retries
        long added = 0;
        for (Span s : accepted) added += ingest(s, zone);
        lastEnd = high;
        prune(zone);
        return added;
    }

    /** Splits a span into minute buckets (across midnight too) and updates the trees. */
    private long ingest(Span s, ZoneOffset zone) {
        names.put(s.app(), s.name());
        long added = 0;
        long t = s.start();
        while (t < s.end()) {
            LocalDateTime local = LocalDateTime.ofInstant(Instant.ofEpochMilli(t), zone);
            long minuteStart = t - (local.getSecond() * 1000L + local.getNano() / 1_000_000);
            long minuteEnd = Math.min(s.end(), minuteStart + 60_000);
            long secondsMs = minuteEnd - t;
            Day day = days.computeIfAbsent(local.toLocalDate(), d -> new Day());
            int minute = local.getHour() * 60 + local.getMinute();
            long seconds = Math.round(secondsMs / 1000.0);
            if (seconds > 0) {
                // Never more than 60 s in a minute, even if rounding pushes it over.
                long room = 60 - day.all.get(minute);
                long add = Math.min(seconds, Math.max(0, room));
                if (add > 0) {
                    day.tree(s.app()).add(minute, add);
                    day.all.add(minute, add);
                    added += add;
                }
            }
            t = minuteEnd;
        }
        LocalDate first = LocalDateTime.ofInstant(Instant.ofEpochMilli(s.start()), zone).toLocalDate();
        days.computeIfAbsent(first, d -> new Day()).spans.add(s);
        return added;
    }

    /** Today's summary: total, top apps, hourly bars, busiest hour, longest focus. */
    public synchronized Map<String, Object> today(int utcOffsetMinutes) {
        ZoneOffset zone = zone(utcOffsetMinutes);
        LocalDate date = LocalDateTime.ofInstant(Instant.ofEpochMilli(clock.getAsLong()), zone).toLocalDate();
        return summary(date);
    }

    public synchronized Map<String, Object> summary(LocalDate date) {
        Day day = days.get(date);
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Segment tree per app per day (1,440 minute leaves): range sums and maxima");
        m.put("date", date.toString());
        long total = day == null ? 0 : day.all.sum(0, MINUTES);
        m.put("totalSeconds", total);
        List<Long> hourly = new ArrayList<>(24);
        int busiest = -1;
        long best = 0;
        for (int h = 0; h < 24; h++) {
            long v = day == null ? 0 : day.all.sum(h * 60, h * 60 + 60);
            hourly.add(v);
            if (v > best) { best = v; busiest = h; }
        }
        m.put("hourly", hourly);
        if (busiest >= 0) {
            m.put("busiestHour", busiest);
            m.put("busiestHourSeconds", best);
        }
        List<Map<String, Object>> apps = new ArrayList<>();
        if (day != null) {
            day.perApp.forEach((app, tree) -> {
                long secs = tree.sum(0, MINUTES);
                if (secs <= 0) return;
                Map<String, Object> a = new LinkedHashMap<>();
                a.put("app", app);
                a.put("name", names.getOrDefault(app, app));
                a.put("seconds", secs);
                List<Long> h = new ArrayList<>(24);
                for (int hr = 0; hr < 24; hr++) h.add(tree.sum(hr * 60, hr * 60 + 60));
                a.put("hourly", h);
                apps.add(a);
            });
        }
        apps.sort((x, y) -> Long.compare((Long) y.get("seconds"), (Long) x.get("seconds")));
        m.put("apps", apps.size() > 12 ? apps.subList(0, 12) : apps);
        m.put("appCount", apps.size());
        Map<String, Object> focus = longestFocus(day);
        if (focus != null) m.put("longestFocus", focus);
        return m;
    }

    /** Seconds {@code app} was in front between two instants (any days kept). */
    public synchronized long range(String app, long from, long to, int utcOffsetMinutes) {
        if (to < from) throw new IllegalArgumentException("'to' is before 'from'");
        if (to - from > (long) KEEP_DAYS * 24 * 3600 * 1000) throw new IllegalArgumentException("range longer than " + KEEP_DAYS + " days");
        ZoneOffset zone = zone(utcOffsetMinutes);
        LocalDateTime a = LocalDateTime.ofInstant(Instant.ofEpochMilli(from), zone);
        LocalDateTime b = LocalDateTime.ofInstant(Instant.ofEpochMilli(to), zone);
        long total = 0;
        for (LocalDate d = a.toLocalDate(); !d.isAfter(b.toLocalDate()); d = d.plusDays(1)) {
            Day day = days.get(d);
            if (day == null) continue;
            SegmentTree t = app == null ? day.all : day.perApp.get(app);
            if (t == null) continue;
            int lo = d.equals(a.toLocalDate()) ? a.getHour() * 60 + a.getMinute() : 0;
            int hi = d.equals(b.toLocalDate()) ? b.getHour() * 60 + b.getMinute() : MINUTES;
            if (hi > lo) total += t.sum(lo, hi);
        }
        return total;
    }

    /**
     * For Workspaces: each 15-minute block (of each day since {@code fromDate}) as the set of
     * apps that were in front for at least {@code minSeconds} of it.
     */
    public synchronized List<List<String>> blocks(LocalDate fromDate, int blockMinutes, int minSeconds) {
        List<List<String>> out = new ArrayList<>();
        for (Map.Entry<LocalDate, Day> e : days.tailMap(fromDate, true).entrySet()) {
            Day day = e.getValue();
            for (int b = 0; b < MINUTES; b += blockMinutes) {
                if (day.all.sum(b, Math.min(MINUTES, b + blockMinutes)) < minSeconds) continue;
                List<String> apps = new ArrayList<>();
                for (Map.Entry<String, SegmentTree> a : day.perApp.entrySet()) {
                    if (a.getValue().sum(b, Math.min(MINUTES, b + blockMinutes)) >= minSeconds) apps.add(a.getKey());
                }
                if (!apps.isEmpty()) out.add(apps);
            }
        }
        return out;
    }

    /** Total seconds per app since {@code fromDate}. */
    public synchronized Map<String, Long> totalsSince(LocalDate fromDate) {
        Map<String, Long> t = new HashMap<>();
        for (Day day : days.tailMap(fromDate, true).values()) {
            day.perApp.forEach((app, tree) -> t.merge(app, tree.sum(0, MINUTES), Long::sum));
        }
        return t;
    }

    public synchronized String name(String app) { return names.getOrDefault(app, app); }

    public synchronized LocalDate today(ZoneOffset zone) {
        return LocalDateTime.ofInstant(Instant.ofEpochMilli(clock.getAsLong()), zone).toLocalDate();
    }

    public synchronized Map<String, Object> stats() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Segment tree (range sum / max)");
        m.put("days", days.size());
        int trees = 0, spans = 0;
        for (Day d : days.values()) { trees += d.perApp.size() + 1; spans += d.spans.size(); }
        m.put("segmentTrees", trees);
        m.put("spans", spans);
        m.put("apps", names.size());
        return m;
    }

    // ---- helpers -------------------------------------------------------------------------------

    /** The longest run of one app in front, joining spans of the same app less than a minute apart. */
    private Map<String, Object> longestFocus(Day day) {
        if (day == null || day.spans.isEmpty()) return null;
        List<Span> spans = new ArrayList<>(day.spans);
        spans.sort((a, b) -> Long.compare(a.start(), b.start()));
        String bestApp = null;
        long bestLen = 0, bestStart = 0;
        String app = null;
        long runStart = 0, runEnd = 0;
        for (Span s : spans) {
            if (s.app().equals(app) && s.start() - runEnd <= 60_000) {
                runEnd = Math.max(runEnd, s.end());
            } else {
                app = s.app();
                runStart = s.start();
                runEnd = s.end();
            }
            if (runEnd - runStart > bestLen) {
                bestLen = runEnd - runStart;
                bestApp = app;
                bestStart = runStart;
            }
        }
        Map<String, Object> f = new LinkedHashMap<>();
        f.put("app", bestApp);
        f.put("name", names.getOrDefault(bestApp, bestApp));
        f.put("seconds", bestLen / 1000);
        f.put("start", bestStart);
        return f;
    }

    private void validate(Span s, long now) {
        if (s.app() == null || s.app().isBlank() || s.app().length() > 200) {
            throw new IllegalArgumentException("'app' must be 1–200 characters");
        }
        if (s.name() == null || s.name().isBlank() || s.name().length() > 120) {
            throw new IllegalArgumentException("'name' must be 1–120 characters");
        }
        if (s.end() <= s.start()) throw new IllegalArgumentException("a span must end after it starts");
        if (s.end() - s.start() > MAX_SPAN_MS) throw new IllegalArgumentException("a span can't be longer than 12 hours");
        if (s.end() > now + 60_000) throw new IllegalArgumentException("a span can't end in the future");
    }

    private void prune(ZoneOffset zone) {
        LocalDate cutoff = today(zone).minusDays(KEEP_DAYS);
        while (!days.isEmpty() && days.firstKey().isBefore(cutoff)) days.pollFirstEntry();
    }

    static ZoneOffset zone(int utcOffsetMinutes) {
        if (utcOffsetMinutes < -18 * 60 || utcOffsetMinutes > 18 * 60) {
            throw new IllegalArgumentException("'tz' must be a UTC offset in minutes (−1080…1080)");
        }
        return ZoneOffset.ofTotalSeconds(utcOffsetMinutes * 60);
    }

    private static String csv(String s) { return s.replace(',', ' ').replace('\n', ' '); }

    private void append(List<String> lines) {
        if (file == null || lines.isEmpty()) return;
        try {
            Path dir = file.toAbsolutePath().getParent();
            if (dir != null) Files.createDirectories(dir);
            try (BufferedWriter w = Files.newBufferedWriter(file, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND)) {
                for (String l : lines) { w.write(l); w.newLine(); }
            }
        } catch (IOException e) {
            throw new UncheckedIOException("couldn't save screen time", e);
        }
    }

    /**
     * Rebuilds the trees from the CSV. Damaged lines (a torn write, bad UTF-8) are skipped, and
     * the file is rewritten without them and without days past {@link #KEEP_DAYS}.
     */
    private void load() {
        List<String> keep = new ArrayList<>();
        int dropped = 0;
        try {
            long cutoff = clock.getAsLong() - (long) (KEEP_DAYS + 1) * 24 * 3600 * 1000;
            String content = java.nio.charset.StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPLACE)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPLACE)
                    .decode(java.nio.ByteBuffer.wrap(Files.readAllBytes(file))).toString();
            for (String line : content.split("\n")) {
                if (line.isBlank()) continue;
                String[] p = line.split(",", 5);
                try {
                    if (p.length != 5 || line.indexOf('\uFFFD') >= 0) throw new IllegalArgumentException("damaged");
                    long start = Long.parseLong(p[0]), end = Long.parseLong(p[1]);
                    int tz = Integer.parseInt(p[2]);
                    if (end <= start || end - start > MAX_SPAN_MS) throw new IllegalArgumentException("bad span");
                    if (end < cutoff) { dropped++; continue; }
                    ingest(new Span(p[3], p[4], Math.max(start, lastEnd), end), zone(tz));
                    lastEnd = Math.max(lastEnd, end);
                    keep.add(line);
                } catch (RuntimeException skip) {
                    dropped++;
                }
            }
        } catch (IOException e) {
            System.err.println("[notchi-backend] couldn't read " + file + ": " + e.getMessage());
            return;
        }
        if (dropped > 0) {
            try {
                Path tmp = file.resolveSibling(file.getFileName() + ".tmp");
                Files.write(tmp, keep, StandardCharsets.UTF_8);
                Files.move(tmp, file, java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                        java.nio.file.StandardCopyOption.ATOMIC_MOVE);
            } catch (IOException e) {
                System.err.println("[notchi-backend] couldn't compact " + file + ": " + e.getMessage());
            }
        }
    }

    /** For the demo and tests: adds a span without the "not in the future" check. */
    synchronized void addUnchecked(Span s, int utcOffsetMinutes) {
        long start = Math.max(s.start(), lastEnd);
        if (s.end() <= start) return;
        ingest(new Span(s.app(), s.name(), start, s.end()), zone(utcOffsetMinutes));
        lastEnd = s.end();
    }
}
