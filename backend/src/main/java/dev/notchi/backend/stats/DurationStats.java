package dev.notchi.backend.stats;

import dev.notchi.backend.algo.select.RandomizedSelect;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.random.RandomGenerator;

/**
 * How long Claude runs usually take, per terminal tab, so the island can show an ETA
 * ("usually done in ~2:14") next to the running timer.
 *
 * <p>Every finished run (from Claude Code's hooks) adds one duration. Percentiles come from
 * {@link RandomizedSelect}: expected O(n) per percentile instead of sorting (O(n log n)).
 * A tab with fewer than {@link #MIN_SAMPLES} runs falls back to all tabs together.
 *
 * <p>Durations are appended to a CSV file ({@code epochMillis,key,seconds}) so the history
 * survives restarts.
 */
public final class DurationStats {

    public static final int MIN_SAMPLES = 5;
    public static final double MAX_SECONDS = 7 * 24 * 3600;
    public static final String ALL = "*";

    private final Map<String, DoubleList> byKey = new HashMap<>();
    private final DoubleList all = new DoubleList();
    private final Path file;
    private final RandomGenerator random;

    /** @param file CSV to load and append to, or null to keep everything in memory */
    public DurationStats(Path file, RandomGenerator random) {
        this.file = file;
        this.random = random;
        if (file != null && Files.exists(file)) load(file);
    }

    /** Records one finished run. */
    public synchronized void record(String key, double seconds) {
        String k = normalizeKey(key);
        validateSeconds(seconds);
        add(k, seconds);
        append(List.of(System.currentTimeMillis() + "," + k + "," + seconds));
    }

    /** Appends lines to the history file in one go (no-op when running in memory). */
    private void append(List<String> lines) {
        if (file == null || lines.isEmpty()) return;
        try {
            Path dir = file.toAbsolutePath().getParent();
            if (dir != null) Files.createDirectories(dir);
            try (BufferedWriter w = Files.newBufferedWriter(file, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND)) {
                for (String line : lines) {
                    w.write(line);
                    w.newLine();
                }
            }
        } catch (IOException ex) {
            throw new UncheckedIOException("couldn't save durations", ex);
        }
    }

    /**
     * Imports a CSV of past runs. Lines are {@code key,seconds} or {@code epochMillis,key,seconds}.
     * Blank lines are skipped, and so is a first line ending in "seconds" (a header). Returns how
     * many rows were added. All or nothing: the first invalid row is reported with its line
     * number, and then nothing is added.
     */
    public synchronized int importCsv(List<String> lines) {
        record Row(String key, double seconds) {}
        java.util.ArrayList<Row> rows = new java.util.ArrayList<>();
        for (int i = 0; i < lines.size(); i++) {
            String line = lines.get(i).strip();
            if (line.isEmpty()) continue;
            String[] parts = line.split(",");
            boolean header = rows.isEmpty() && parts[parts.length - 1].strip().equalsIgnoreCase("seconds");
            if (header) continue;
            if (parts.length < 2 || parts.length > 3) {
                throw new IllegalArgumentException("line " + (i + 1) + ": expected key,seconds");
            }
            String key = parts[parts.length - 2];
            double seconds;
            try {
                seconds = Double.parseDouble(parts[parts.length - 1].strip());
            } catch (NumberFormatException ex) {
                throw new IllegalArgumentException("line " + (i + 1) + ": seconds is not a number");
            }
            try {
                validateSeconds(seconds);
                rows.add(new Row(normalizeKey(key), seconds));
            } catch (IllegalArgumentException ex) {
                throw new IllegalArgumentException("line " + (i + 1) + ": " + ex.getMessage());
            }
        }
        long now = System.currentTimeMillis();
        java.util.ArrayList<String> out = new java.util.ArrayList<>(rows.size());
        for (Row r : rows) {
            add(r.key, r.seconds);
            out.add(now + "," + r.key + "," + r.seconds);
        }
        append(out);
        return rows.size();
    }

    /**
     * p50 / p90 / p99 for a tab (or for everything with {@link #ALL}).
     * {@code enough = false} when there isn't enough history yet.
     */
    public synchronized Map<String, Object> summary(String key) {
        String k = key == null ? ALL : normalizeKey(key);
        DoubleList list = k.equals(ALL) ? all : byKey.get(k);
        String scope = k;
        if (list == null || list.size() < MIN_SAMPLES) {
            list = all;
            scope = ALL;
        }
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("key", k);
        m.put("scope", scope.equals(ALL) ? "all tabs" : scope);
        m.put("count", list.size());
        m.put("algorithm", "Randomized Quickselect");
        if (list.size() < MIN_SAMPLES) {
            m.put("enough", false);
            m.put("needed", MIN_SAMPLES);
            return m;
        }
        double[] data = list.toArray();
        RandomizedSelect sel = new RandomizedSelect(random);
        long t0 = System.nanoTime();
        double p50 = sel.percentile(data, 50);
        double p90 = sel.percentile(data, 90);
        double p99 = sel.percentile(data, 99);
        long took = System.nanoTime() - t0;
        double min = data[0], max = data[0];
        for (double v : data) {
            min = Math.min(min, v);
            max = Math.max(max, v);
        }
        m.put("enough", true);
        m.put("p50", p50);
        m.put("p90", p90);
        m.put("p99", p99);
        m.put("min", min);
        m.put("max", max);
        m.put("comparisons", sel.comparisons());
        m.put("tookMicros", took / 1000.0);
        return m;
    }

    public synchronized Map<String, Object> stats() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Randomized Quickselect");
        m.put("runs", all.size());
        Map<String, Integer> perKey = new LinkedHashMap<>();
        byKey.entrySet().stream().sorted(Map.Entry.comparingByKey())
                .forEach(e -> perKey.put(e.getKey(), e.getValue().size()));
        m.put("perTab", perKey);
        return m;
    }

    // ---- helpers -----------------------------------------------------------------------

    private void add(String k, double seconds) {
        byKey.computeIfAbsent(k, x -> new DoubleList()).add(seconds);
        all.add(seconds);
    }

    private void load(Path f) {
        try {
            String content = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPLACE)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPLACE)
                    .decode(java.nio.ByteBuffer.wrap(Files.readAllBytes(f))).toString();
            for (String line : content.split("\n")) {
                String[] p = line.split(",");
                if (p.length != 3) continue;
                try {
                    double s = Double.parseDouble(p[2]);
                    if (s > 0 && s <= MAX_SECONDS) add(normalizeKey(p[1]), s);
                } catch (IllegalArgumentException ignored) {   // includes NumberFormatException
                    // A damaged line in the history file shouldn't stop the backend.
                }
            }
        } catch (IOException ex) {
            System.err.println("[notchi-backend] couldn't read " + f + ": " + ex.getMessage());
        }
    }

    static String normalizeKey(String key) {
        if (key == null || key.isBlank()) throw new IllegalArgumentException("'key' must not be blank");
        String k = key.strip().toLowerCase(Locale.ROOT).replace(',', ' ').replace('\n', ' ');
        if (k.length() > 100) throw new IllegalArgumentException("'key' longer than 100 characters");
        return k;
    }

    private static void validateSeconds(double s) {
        if (Double.isNaN(s) || s <= 0 || s > MAX_SECONDS) {
            throw new IllegalArgumentException("'seconds' must be > 0 and at most 7 days");
        }
    }

}
