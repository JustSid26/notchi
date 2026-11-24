package dev.notchi.backend.http;

import dev.notchi.backend.algo.bloom.BloomFilter;
import dev.notchi.backend.algo.select.RandomizedSelect;
import dev.notchi.backend.algo.select.SelectBaselines;
import dev.notchi.backend.json.Json;
import dev.notchi.backend.launcher.Launcher;
import dev.notchi.backend.live.LiveActivity;
import dev.notchi.backend.live.LiveQueue;
import dev.notchi.backend.stats.DurationStats;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The REST endpoints. Each handler validates its input, calls one service and returns JSON.
 * See backend/README.md for request/response examples.
 */
public final class NotchiApi {

    public static final String VERSION = "1.0.0";
    /** Different every time the backend starts, so the app can tell it restarted. */
    private static final String INSTANCE = Long.toString(System.currentTimeMillis(), 36)
            + Long.toString(System.nanoTime() & 0xffff, 36);

    private final LiveQueue live;
    private final Launcher launcher;
    private final DurationStats durations;

    public NotchiApi(LiveQueue live, Launcher launcher, DurationStats durations) {
        this.live = live;
        this.launcher = launcher;
        this.durations = durations;
    }

    public ApiServer register(ApiServer s) {
        s.route("GET", "/api/health", r -> health());
        s.route("GET", "/api/stats", r -> stats());

        // LIVE queue: indexed binary heap + Bloom-filter duplicate screening
        s.route("POST", "/api/live/events", this::pushEvent);
        s.route("GET", "/api/live", r -> listLive(r.intQuery("limit", 20)));
        s.route("DELETE", "/api/live/{id}", r -> Map.of("removed", live.end(r.param(0)), "version", live.version()));
        s.route("PUT", "/api/live/dedupe", this::configureDedupe);

        // Launcher: trie prefix search
        s.route("PUT", "/api/launcher/catalog", this::replaceCatalog);
        s.route("GET", "/api/launcher/search", r -> launcher.search(r.query("q"), r.intQuery("k", 6)));
        s.route("POST", "/api/launcher/use", r -> launcher.use(r.fields().string("id")));

        // Claude ETA: randomized quickselect over past run durations
        s.route("POST", "/api/durations", this::recordDuration);
        s.route("POST", "/api/durations/import", r -> Map.of("imported", durations.importCsv(lines(r.body()))));
        s.route("GET", "/api/durations/summary", r -> durations.summary(r.query("key")));

        // Lab: run an algorithm on your own data and compare it with its baseline
        s.route("POST", "/api/lab/select", this::labSelect);
        s.route("POST", "/api/lab/bloom", this::labBloom);
        return s;
    }

    // ---- handlers ------------------------------------------------------------------------

    private Map<String, Object> health() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("status", "ok");
        m.put("version", VERSION);
        m.put("instance", INSTANCE);
        m.put("java", System.getProperty("java.version"));
        m.put("algorithms", List.of(
                "Indexed binary heap (LIVE priority + expiry)",
                "Bloom filter (duplicate event screening)",
                "Trie (launcher prefix search)",
                "Randomized Quickselect (Claude ETA percentiles)"));
        return m;
    }

    private Map<String, Object> stats() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("live", live.stats());
        m.put("launcher", launcher.stats());
        m.put("durations", durations.stats());
        return m;
    }

    private Object pushEvent(ApiServer.Request r) {
        Json.Fields f = r.fields();
        LiveQueue.Event e = parseEvent(f);
        int k = r.intQuery("limit", 20);
        LiveQueue.Result res = live.ingest(e, clampLimit(k));
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("accepted", res.accepted());
        m.put("verdict", switch (res.verdict()) {
            case NEW -> "new";
            case NEW_AFTER_FALSE_POSITIVE -> "new-after-false-positive";
            case DUPLICATE -> "duplicate";
        });
        m.put("size", res.size());
        m.put("version", res.version());
        m.put("order", res.top().stream().map(LiveActivity::id).toList());
        return m;
    }

    private Object listLive(int limit) {
        LiveQueue.Snapshot snap = live.snapshot(clampLimit(limit));
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Indexed binary heap, top-k by urgency");
        m.put("size", snap.size());
        m.put("version", snap.version());
        m.put("items", snap.top().stream().map(LiveActivity::toJson).toList());
        return m;
    }

    private Object configureDedupe(ApiServer.Request r) {
        Json.Fields f = r.fields();
        double expected = f.number("expected");
        if (expected != Math.rint(expected)) throw new IllegalArgumentException("'expected' must be a whole number");
        live.dedupe().configure((long) expected, f.number("fpp"));
        return live.dedupe().stats();
    }

    private Object replaceCatalog(ApiServer.Request r) {
        List<Object> raw = r.fields().list("items");
        List<Launcher.Entry> entries = new ArrayList<>(raw.size());
        for (int i = 0; i < raw.size(); i++) {
            if (!(raw.get(i) instanceof Map<?, ?> map)) {
                throw new IllegalArgumentException("items[" + i + "] must be an object");
            }
            @SuppressWarnings("unchecked")
            Json.Fields f = new Json.Fields((Map<String, Object>) map);
            try {
                entries.add(new Launcher.Entry(limited(f.string("id"), "id", 500), limited(f.string("label"), "label", 120),
                        f.string("kind"), f.optString("path")));
            } catch (IllegalArgumentException ex) {
                throw new IllegalArgumentException("items[" + i + "]: " + ex.getMessage());
            }
        }
        return launcher.replaceCatalog(entries);
    }

    private Object recordDuration(ApiServer.Request r) {
        Json.Fields f = r.fields();
        String key = f.string("key");
        durations.record(key, f.number("seconds"));
        return durations.summary(key);
    }

    private Object labSelect(ApiServer.Request r) {
        Json.Fields f = r.fields();
        List<Object> raw = f.list("values");
        if (raw.isEmpty()) throw new IllegalArgumentException("'values' must not be empty");
        if (raw.size() > 200_000) throw new IllegalArgumentException("at most 200,000 values");
        double[] values = new double[raw.size()];
        for (int i = 0; i < values.length; i++) {
            if (!(raw.get(i) instanceof Number n)) throw new IllegalArgumentException("values[" + i + "] is not a number");
            values[i] = n.doubleValue();
        }
        List<Object> ps = f.has("percentiles") ? f.list("percentiles") : List.of(50L, 90L, 99L);
        List<Map<String, Object>> out = new ArrayList<>();
        for (Object o : ps) {
            if (!(o instanceof Number n)) throw new IllegalArgumentException("percentiles must be numbers");
            double p = n.doubleValue();
            int rank = RandomizedSelect.rankFor(values.length, p);
            RandomizedSelect sel = new RandomizedSelect();
            long t0 = System.nanoTime();
            double v = sel.percentile(values, p);
            long tSel = System.nanoTime() - t0;
            t0 = System.nanoTime();
            double check = SelectBaselines.sortSelect(values, rank);
            long tSort = System.nanoTime() - t0;
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("percentile", p);
            m.put("rank", rank);
            m.put("value", v);
            m.put("matchesSort", v == check);
            m.put("comparisons", sel.comparisons());
            m.put("quickselectMicros", tSel / 1000.0);
            m.put("sortMicros", tSort / 1000.0);
            out.add(m);
        }
        return Map.of("algorithm", "Randomized Quickselect vs sort", "n", values.length, "results", out);
    }

    private Object labBloom(ApiServer.Request r) {
        Json.Fields f = r.fields();
        double expected = f.number("expected");
        if (expected != Math.rint(expected)) throw new IllegalArgumentException("'expected' must be a whole number");
        if (expected < 1 || expected > 5_000_000) throw new IllegalArgumentException("'expected' must be between 1 and 5,000,000");
        double fpp = f.number("fpp");
        if (!(fpp >= 1e-6 && fpp < 1)) throw new IllegalArgumentException("'fpp' must be between 0.000001 and 1");
        BloomFilter bloom = BloomFilter.forExpected((long) expected, fpp);   // at most ~18 MB
        List<Object> inserts = f.list("inserts"), queries = f.list("queries");
        if (inserts.size() + queries.size() > 500_000) throw new IllegalArgumentException("at most 500,000 keys in total");
        Set<String> exact = new HashSet<>();
        for (Object o : inserts) {
            String key = String.valueOf(o);
            bloom.add(key);
            exact.add(key);
        }
        int falsePositives = 0, trueNegatives = 0;
        List<Map<String, Object>> results = new ArrayList<>();
        for (Object o : queries) {
            String key = String.valueOf(o);
            boolean maybe = bloom.mightContain(key);
            boolean actually = exact.contains(key);
            if (maybe && !actually) falsePositives++;
            if (!actually) trueNegatives += maybe ? 0 : 1;
            if (results.size() < 200) {
                results.add(Map.of("key", key, "bloom", maybe ? "possibly present" : "definitely absent",
                        "exact", actually));
            }
        }
        int absent = falsePositives + trueNegatives;
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Bloom filter (double hashing)");
        m.put("bits", bloom.bitCount());
        m.put("hashes", bloom.hashCount());
        m.put("bytes", bloom.sizeInBytes());
        m.put("inserted", inserts.size());
        m.put("fillRatio", bloom.fillRatio());
        m.put("expectedFalsePositiveRate", bloom.expectedFalsePositiveRate());
        m.put("observedFalsePositiveRate", absent == 0 ? 0.0 : (double) falsePositives / absent);
        m.put("falsePositives", falsePositives);
        m.put("results", results);
        return m;
    }

    // ---- validation helpers ---------------------------------------------------------------

    static LiveQueue.Event parseEvent(Json.Fields f) {
        String id = limited(f.string("id"), "id", 200);
        if (id.isBlank()) throw new IllegalArgumentException("'id' must not be blank");
        LiveActivity.State state = LiveActivity.State.parse(f.string("state"));
        String title = f.has("title") ? limited(f.string("title"), "title", 200) : id;
        if (title.isBlank()) throw new IllegalArgumentException("'title' must not be blank");
        Double progress = f.optNumber("progress");
        if (progress != null && !(progress >= 0 && progress <= 1)) {
            throw new IllegalArgumentException("'progress' must be between 0 and 1");
        }
        long ttl = defaultTtl(state);
        if (f.has("ttl")) {
            double t = f.number("ttl");
            if (!(t >= 0 && t <= LiveQueue.MAX_TTL_SECONDS)) {
                throw new IllegalArgumentException("'ttl' must be between 0 and " + LiveQueue.MAX_TTL_SECONDS + " seconds");
            }
            ttl = (long) Math.ceil(t);
        }
        String eventId = f.optString("eventId");
        if (eventId != null) {
            limited(eventId, "eventId", 256);
            if (eventId.isBlank()) throw new IllegalArgumentException("'eventId' must not be blank");
        }
        return new LiveQueue.Event(eventId, id, title, opt(f, "subtitle", 300), state, progress,
                opt(f, "icon", 100), opt(f, "tint", 40), ttl);
    }

    /** Same defaults as the Mac app: running 30 min, needs-you 30 s, done/failed 6 s. */
    static long defaultTtl(LiveActivity.State s) {
        return switch (s) {
            case RUNNING -> 1800;
            case ATTENTION -> 30;
            case DONE, FAILED -> 6;
        };
    }

    private static String opt(Json.Fields f, String k, int max) {
        String v = f.optString(k);
        return v == null ? null : limited(v, k, max);
    }

    private static String limited(String v, String name, int max) {
        if (v.length() > max) throw new IllegalArgumentException("'" + name + "' longer than " + max + " characters");
        return v;
    }

    private static int clampLimit(int k) {
        if (k < 1 || k > 500) throw new IllegalArgumentException("'limit' must be between 1 and 500");
        return k;
    }

    private static List<String> lines(String body) {
        if (body == null || body.isBlank()) throw new IllegalArgumentException("CSV body is required");
        return body.lines().toList();
    }
}
