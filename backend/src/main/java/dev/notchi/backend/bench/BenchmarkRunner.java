package dev.notchi.backend.bench;

import dev.notchi.backend.algo.bloom.BloomFilter;
import dev.notchi.backend.algo.heap.IndexedBinaryHeap;
import dev.notchi.backend.algo.select.RandomizedSelect;
import dev.notchi.backend.algo.select.SelectBaselines;
import dev.notchi.backend.algo.trie.Trie;
import dev.notchi.backend.live.LiveActivity;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.function.LongSupplier;

/**
 * Compares each algorithm with a baseline on inputs of three increasing sizes and writes
 * {@code docs/benchmarks.md} and {@code docs/benchmarks.csv}.
 *
 * <p>Method: fixed random seeds; every measurement is run {@value #WARMUP} times to warm up
 * the JIT, then {@value #RUNS} times, and the median is reported. Wall-clock time via
 * {@link System#nanoTime()}. Run it on an idle machine:
 *
 * <pre>  ./mvnw -q package -DskipTests && java -cp target/notchi-backend.jar dev.notchi.backend.bench.BenchmarkRunner</pre>
 */
public final class BenchmarkRunner {

    static final int WARMUP = 2;
    static final int RUNS = 5;

    private final StringBuilder md = new StringBuilder();
    private final List<String> csv = new ArrayList<>(List.of("experiment,size,variant,median_ms,extra"));

    public static void main(String[] args) throws IOException {
        Path out = Path.of(args.length > 0 ? args[0] : "docs");
        BenchmarkRunner b = new BenchmarkRunner();
        b.header();
        jitWarmUp();
        b.liveQueue();
        b.launcher();
        b.bloom();
        b.select();
        Files.createDirectories(out);
        Files.writeString(out.resolve("benchmarks.md"), b.md.toString(), StandardCharsets.UTF_8);
        Files.write(out.resolve("benchmarks.csv"), b.csv, StandardCharsets.UTF_8);
        System.out.println("Wrote " + out.resolve("benchmarks.md") + " and benchmarks.csv");
    }

    /** Runs every algorithm briefly so the first table isn't measuring the JIT compiler. */
    static void jitWarmUp() {
        List<LiveActivity> acts = activities(2_000, new Random(0));
        Random r = new Random(0);
        for (int round = 0; round < 20; round++) {
            IndexedBinaryHeap<String, LiveActivity> h = new IndexedBinaryHeap<>(LiveActivity.URGENCY);
            for (LiveActivity a : acts) h.push(a.id(), a);
            for (int i = 0; i < 2_000; i++) {
                LiveActivity a = acts.get(r.nextInt(acts.size()));
                h.update(a.id(), touched(a, r, i));
                h.topK(10);
            }
            double[] d = new double[20_000];
            for (int i = 0; i < d.length; i++) d[i] = r.nextDouble();
            new RandomizedSelect(r).select(d, d.length / 2);
            BloomFilter f = BloomFilter.forExpected(10_000, 0.01);
            for (int i = 0; i < 10_000; i++) f.mightContain("w" + i);
        }
    }

    // ---- 1. LIVE queue: indexed heap vs re-sorting -------------------------------------------

    void liveQueue() {
        section("1. LIVE queue: indexed binary heap vs re-sorting on every read",
                "Workload: n activities, then 100 rounds of *update one random activity + read the top 10* "
                + "(what the island does on each event). Baseline: a hash map of activities, sorted on every read.");
        table("| n | heap (ms) | re-sort (ms) | speed-up |", "|---:|---:|---:|---:|");
        for (int n : new int[]{1_000, 10_000, 100_000}) {
            List<LiveActivity> base = activities(n, new Random(n));
            int rounds = 100;
            double heap = median(() -> {
                IndexedBinaryHeap<String, LiveActivity> h = new IndexedBinaryHeap<>(LiveActivity.URGENCY);
                for (LiveActivity a : base) h.push(a.id(), a);
                Random r = new Random(1);
                long t0 = System.nanoTime();
                long sink = 0;
                for (int i = 0; i < rounds; i++) {
                    LiveActivity a = base.get(r.nextInt(n));
                    h.update(a.id(), touched(a, r, i));
                    sink += h.topK(10).size();
                }
                return System.nanoTime() - t0 + (sink == -1 ? 1 : 0);
            });
            double sort = median(() -> {
                Map<String, LiveActivity> m = new HashMap<>();
                for (LiveActivity a : base) m.put(a.id(), a);
                Random r = new Random(1);
                long t0 = System.nanoTime();
                long sink = 0;
                for (int i = 0; i < rounds; i++) {
                    LiveActivity a = base.get(r.nextInt(n));
                    m.put(a.id(), touched(a, r, i));
                    List<LiveActivity> all = new ArrayList<>(m.values());
                    all.sort(LiveActivity.URGENCY.reversed());
                    sink += all.subList(0, 10).size();
                }
                return System.nanoTime() - t0 + (sink == -1 ? 1 : 0);
            });
            row(n, fmt(heap), fmt(sort), speedup(sort / heap));
            csv("live-queue", n, "heap", heap, "");
            csv("live-queue", n, "re-sort", sort, "");
        }
        note("Per round the heap does O(log n) for the update and O(k log k) for the top 10; re-sorting is "
                + "O(n log n). The gap grows with n, as expected.");
    }

    private static List<LiveActivity> activities(int n, Random r) {
        LiveActivity.State[] states = LiveActivity.State.values();
        List<LiveActivity> out = new ArrayList<>(n);
        for (int i = 0; i < n; i++) {
            out.add(new LiveActivity("a" + i, "Activity " + i, null, states[r.nextInt(states.length)],
                    null, null, null, r.nextInt(1_000_000), 0));
        }
        return out;
    }

    private static LiveActivity touched(LiveActivity a, Random r, int i) {
        LiveActivity.State[] states = LiveActivity.State.values();
        return new LiveActivity(a.id(), a.title(), null, states[r.nextInt(states.length)], null, null, null,
                1_000_000 + i, 0);
    }

    // ---- 2. Launcher: trie vs linear scan ------------------------------------------------------

    void launcher() {
        section("2. Launcher search: trie vs scanning every item",
                "Catalog of n synthetic app/command names (1–3 words from a 400-word vocabulary). 500 queries, "
                + "each a 1–4 letter prefix of a real word, top 6 results. Baseline: check every item's word starts, "
                + "then sort the matches.");
        table("| n | prefix | trie (µs/query) | scan (µs/query) | speed-up | trie nodes |", "|---:|---:|---:|---:|---:|---:|");
        String[] vocab = vocabulary(400, new Random(3));
        for (int n : new int[]{1_000, 10_000, 100_000}) {
            Random r = new Random(n);
            Trie<String> trie = new Trie<>();
            for (int i = 0; i < n; i++) {
                int words = 1 + r.nextInt(3);
                StringBuilder b = new StringBuilder();
                for (int w = 0; w < words; w++) b.append(w == 0 ? "" : " ").append(vocab[r.nextInt(vocab.length)]);
                trie.insert("id" + i, b.toString(), null, r.nextInt(100));
            }
            for (int len : new int[]{1, 2, 4}) {
                String[] queries = new String[500];
                Random qr = new Random(len);
                for (int i = 0; i < queries.length; i++) {
                    String w = vocab[qr.nextInt(vocab.length)];
                    queries[i] = w.substring(0, Math.min(len, w.length()));
                }
                double t = median(() -> {
                    long t0 = System.nanoTime(), sink = 0;
                    for (String q : queries) sink += trie.search(q, 6).size();
                    return System.nanoTime() - t0 + (sink == -1 ? 1 : 0);
                }) * 1000 / queries.length;
                double s = median(() -> {
                    long t0 = System.nanoTime(), sink = 0;
                    for (String q : queries) sink += Trie.linearSearch(trie.items(), q, 6).size();
                    return System.nanoTime() - t0 + (sink == -1 ? 1 : 0);
                }) * 1000 / queries.length;
                row(n, len, fmt(t), fmt(s), speedup(s / t), trie.nodeCount());
                csv("launcher", n, "trie-prefix" + len, t / 1000, "");
                csv("launcher", n, "scan-prefix" + len, s / 1000, "");
            }
        }
        note("The trie only visits the subtree under the prefix, so longer prefixes (smaller subtrees) are "
                + "fastest. A one-letter prefix still touches ~1/26 of the catalog; the scan always touches all of it.");
    }

    private static String[] vocabulary(int size, Random r) {
        String letters = "abcdefghijklmnopqrstuvwxyz";
        HashSet<String> words = new HashSet<>();
        while (words.size() < size) {
            int len = 3 + r.nextInt(6);
            StringBuilder b = new StringBuilder();
            for (int i = 0; i < len; i++) b.append(letters.charAt(r.nextInt(26)));
            words.add(b.toString());
        }
        return words.toArray(new String[0]);
    }

    // ---- 3. Duplicate screening: Bloom filter vs exact hash set -------------------------------

    void bloom() {
        section("3. Duplicate screening: Bloom filter vs an exact hash set",
                "n distinct event ids are inserted (filter sized for n at 1%), then n *new* ids are queried. "
                + "Memory: the filter's bit array vs the retained heap of a HashSet<String> of the same ids "
                + "(measured after GC; approximate).");
        table("| n | Bloom memory | HashSet memory | ratio | target FPR | expected FPR | observed FPR | Bloom ns/lookup | HashSet ns/lookup |",
                "|---:|---:|---:|---:|---:|---:|---:|---:|---:|");
        for (int n : new int[]{10_000, 100_000, 1_000_000}) {
            String[] in = new String[n], out = new String[n];
            for (int i = 0; i < n; i++) {
                in[i] = "claude:" + (i * 7919L) + ":done";
                out[i] = "deploy:" + (i * 104729L) + ":running";
            }
            BloomFilter f = BloomFilter.forExpected(n, 0.01);
            for (String s : in) f.add(s);
            long setBytes = retainedBytes(() -> {
                HashSet<String> set = new HashSet<>();
                for (String s : in) set.add(new String(s));   // own copies, like ids parsed from requests
                return set;
            });
            HashSet<String> set = new HashSet<>(Arrays.asList(in));
            int fp = 0;
            for (String s : out) if (f.mightContain(s)) fp++;
            double bloomNs = median(() -> {
                long t0 = System.nanoTime(), sink = 0;
                for (String s : out) if (f.mightContain(s)) sink++;
                return System.nanoTime() - t0 + (sink == -1 ? 1 : 0);
            }) * 1e6 / n;
            double setNs = median(() -> {
                long t0 = System.nanoTime(), sink = 0;
                for (String s : out) if (set.contains(s)) sink++;
                return System.nanoTime() - t0 + (sink == -1 ? 1 : 0);
            }) * 1e6 / n;
            row(n, bytes(f.sizeInBytes()), bytes(setBytes),
                    String.format(Locale.ROOT, "%.0f× smaller", (double) setBytes / f.sizeInBytes()),
                    "1.00%", pct(f.expectedFalsePositiveRate()), pct((double) fp / n), fmt(bloomNs), fmt(setNs));
            csv("bloom", n, "bloom-bytes", f.sizeInBytes(), "fpr=" + (double) fp / n);
            csv("bloom", n, "hashset-bytes", setBytes, "");
        }
        note("The filter needs ~1.2 bytes per id regardless of id length, at the cost of ~1% \"possibly seen\" "
                + "answers, which Notchi confirms against the exact log. In memory a HashSet lookup is faster (a String "
                + "caches its hash code, while the filter hashes the bytes and probes k bits), so the filter does not "
                + "win on speed here. Its wins are memory (~50× smaller) and that the authoritative log, which in a "
                + "real deployment lives in a database or on disk, is skipped for the ~99% of events that are new.");
    }

    private static long retainedBytes(java.util.function.Supplier<Object> build) {
        Runtime rt = Runtime.getRuntime();
        gc();
        long before = rt.totalMemory() - rt.freeMemory();
        Object keep = build.get();
        gc();
        long after = rt.totalMemory() - rt.freeMemory();
        if (keep.hashCode() == 42) System.out.print("");   // keep it reachable until measured
        return Math.max(0, after - before);
    }

    private static void gc() {
        for (int i = 0; i < 3; i++) {
            System.gc();
            try {
                Thread.sleep(50);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
    }

    // ---- 4. Percentiles: randomized quickselect vs sort, and vs a fixed pivot -------------

    void select() {
        section("4a. Claude ETA percentiles: randomized Quickselect vs sorting",
                "n log-normal durations (like real run times). Find the median. Baseline: sort a copy and index it.");
        table("| n | quickselect (ms) | sort (ms) | speed-up | comparisons / n (mean of 25 seeds) |",
                "|---:|---:|---:|---:|---:|");
        for (int n : new int[]{10_000, 100_000, 1_000_000}) {
            Random r = new Random(n);
            double[] data = new double[n];
            for (int i = 0; i < n; i++) data[i] = 120 * Math.exp(0.6 * r.nextGaussian());
            long[] comps = new long[1];
            double sel = median(() -> {
                RandomizedSelect s = new RandomizedSelect(new Random(7));
                long t0 = System.nanoTime();
                double v = s.select(data, n / 2);
                comps[0] = s.comparisons();
                return System.nanoTime() - t0 + (v < -1 ? 1 : 0);
            });
            double sort = median(() -> {
                long t0 = System.nanoTime();
                double v = SelectBaselines.sortSelect(data, n / 2);
                return System.nanoTime() - t0 + (v < -1 ? 1 : 0);
            });
            long total = 0;
            for (int seed = 0; seed < 25; seed++) {
                RandomizedSelect s = new RandomizedSelect(new Random(seed));
                s.select(data, n / 2);
                total += s.comparisons();
            }
            row(n, fmt(sel), fmt(sort), speedup(sort / sel),
                    String.format(Locale.ROOT, "%.2f", total / 25.0 / n));
            csv("select", n, "quickselect", sel, "comparisons=" + comps[0]);
            csv("select", n, "sort", sort, "");
        }
        note("Comparisons per element stay roughly flat as n grows, which is what linear expected time looks like "
                + "(the three-way partition counts up to two comparisons per element per pass). Sorting does "
                + "Θ(n log n) work to answer a question that only needs one rank.");

        section("4b. Why the pivot is random: already-sorted input",
                "The same median search on sorted data (e.g. durations logged in increasing order). "
                + "Baseline: the textbook first-element pivot.");
        table("| n | randomized (ms) | first pivot (ms) | randomized comparisons | first-pivot comparisons |",
                "|---:|---:|---:|---:|---:|");
        for (int n : new int[]{2_000, 8_000, 32_000}) {
            double[] sorted = new double[n];
            for (int i = 0; i < n; i++) sorted[i] = i;
            long[] rc = new long[1], fc = new long[1];
            double rand = median(() -> {
                RandomizedSelect s = new RandomizedSelect(new Random(7));
                long t0 = System.nanoTime();
                double v = s.select(sorted, n / 2);
                rc[0] = s.comparisons();
                return System.nanoTime() - t0 + (v < -1 ? 1 : 0);
            });
            double first = median(() -> {
                long t0 = System.nanoTime();
                SelectBaselines.Counted c = SelectBaselines.firstPivotSelect(sorted, n / 2);
                fc[0] = c.comparisons();
                return System.nanoTime() - t0 + (c.value() < -1 ? 1 : 0);
            });
            row(n, fmt(rand), fmt(first), rc[0], fc[0]);
            csv("select-sorted", n, "randomized", rand, "comparisons=" + rc[0]);
            csv("select-sorted", n, "first-pivot", first, "comparisons=" + fc[0]);
        }
        note("To reach the median the first-element pivot peels off one element per pass: about 3n²/8 comparisons "
                + "(quadratic: 4× the size → ~16× the work); "
                + "the random pivot stays linear on every input, because no input can make it pick badly on purpose.");
    }

    // ---- reporting helpers ----------------------------------------------------------------------

    private void header() {
        md.append("# Benchmarks\n\n")
          .append("Generated by `dev.notchi.backend.bench.BenchmarkRunner`. Re-run it to reproduce; numbers vary by machine.\n\n")
          .append("- Java: ").append(System.getProperty("java.version")).append(" (")
          .append(System.getProperty("java.vm.name")).append(")\n")
          .append("- OS: ").append(System.getProperty("os.name")).append(' ').append(System.getProperty("os.version"))
          .append(" · ").append(System.getProperty("os.arch")).append(" · ")
          .append(Runtime.getRuntime().availableProcessors()).append(" cores\n")
          .append("- Method: fixed seeds, ").append(WARMUP).append(" warm-up runs, median of ").append(RUNS)
          .append(" timed runs (System.nanoTime)\n");
    }

    private void section(String title, String setup) {
        md.append("\n## ").append(title).append("\n\n").append(setup).append("\n\n");
        System.out.println("… " + title);
    }

    private void table(String head, String align) { md.append(head).append('\n').append(align).append('\n'); }

    private void row(Object... cells) {
        md.append('|');
        for (Object c : cells) md.append(' ').append(c).append(" |");
        md.append('\n');
    }

    private void note(String text) { md.append("\n").append(text).append("\n"); }

    private void csv(String exp, int n, String variant, double value, String extra) {
        csv.add(exp + "," + n + "," + variant + "," + String.format(Locale.ROOT, "%.4f", value) + "," + extra);
    }

    /** Median of RUNS timed runs (in ms) after WARMUP untimed ones. */
    private static double median(LongSupplier timedRunNanos) {
        for (int i = 0; i < WARMUP; i++) timedRunNanos.getAsLong();
        double[] t = new double[RUNS];
        for (int i = 0; i < RUNS; i++) t[i] = timedRunNanos.getAsLong() / 1e6;
        Arrays.sort(t);
        return t[RUNS / 2];
    }

    private static String fmt(double v) {
        return v >= 100 ? String.format(Locale.ROOT, "%.0f", v)
             : v >= 1 ? String.format(Locale.ROOT, "%.2f", v)
             : String.format(Locale.ROOT, "%.3f", v);
    }

    private static String speedup(double x) {
        return String.format(Locale.ROOT, x >= 10 ? "%.0f×" : "%.1f×", x);
    }

    private static String pct(double v) { return String.format(Locale.ROOT, "%.2f%%", v * 100); }

    private static String bytes(long b) {
        return b >= 1 << 20 ? String.format(Locale.ROOT, "%.1f MB", b / 1048576.0)
             : String.format(Locale.ROOT, "%.1f KB", b / 1024.0);
    }
}
