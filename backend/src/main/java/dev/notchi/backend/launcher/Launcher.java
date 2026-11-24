package dev.notchi.backend.launcher;

import dev.notchi.backend.algo.trie.Trie;

import java.io.IOException;
import java.io.Reader;
import java.io.UncheckedIOException;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;

/**
 * Type-to-launch search for the island: apps, pinned terminal tabs and Notchi commands.
 *
 * <p>The Mac app sends its catalog (what's installed, which tabs are pinned); the backend
 * indexes it in a {@link Trie} and answers prefix searches ranked by how often each item
 * was launched. Launch counts are saved to a properties file so the ranking learns over time.
 */
public final class Launcher {

    public static final int MAX_ITEMS = 20_000;
    public static final int MAX_RESULTS = 20;

    /** What an entry is, plus anything the Mac app needs to open it. */
    public record Entry(String id, String label, String kind, String path) {
        public Map<String, Object> toJson(long weight) {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", id);
            m.put("label", label);
            m.put("kind", kind);
            if (path != null) m.put("path", path);
            m.put("uses", weight);
            return m;
        }
    }

    private static final Set<String> KINDS = Set.of("app", "tab", "command");

    private Trie<Entry> trie = new Trie<>();
    private final Map<String, Long> uses = new HashMap<>();
    private final Path usesFile;

    /** @param usesFile where launch counts are kept, or null to keep them in memory */
    public Launcher(Path usesFile) {
        this.usesFile = usesFile;
        if (usesFile != null && Files.exists(usesFile)) loadUses();
    }

    /** Replaces the whole catalog. Launch counts are kept by id across replacements. */
    public synchronized Map<String, Object> replaceCatalog(List<Entry> entries) {
        if (entries.size() > MAX_ITEMS) {
            throw new IllegalArgumentException("catalog has more than " + MAX_ITEMS + " items");
        }
        Trie<Entry> fresh = new Trie<>();
        Set<String> ids = new HashSet<>();
        // One bad item (an emoji-only tab name, a duplicate id…) is skipped and reported;
        // it must not take the whole launcher down.
        List<String> skipped = new ArrayList<>();
        for (Entry e : entries) {
            try {
                if (!KINDS.contains(e.kind())) {
                    throw new IllegalArgumentException("kind must be app, tab or command (got '" + e.kind() + "')");
                }
                if (!ids.add(e.id())) throw new IllegalArgumentException("duplicate id");
                fresh.insert(e.id(), e.label(), e, uses.getOrDefault(e.id(), 0L));
            } catch (IllegalArgumentException ex) {
                if (skipped.size() < 20) skipped.add(e.id() + ": " + ex.getMessage());
            }
        }
        trie = fresh;
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("indexed", trie.size());
        m.put("skipped", entries.size() - trie.size());
        if (!skipped.isEmpty()) m.put("skippedItems", skipped);
        m.put("trieNodes", trie.nodeCount());
        return m;
    }

    /** Items with a word starting with {@code query}, most-used first. */
    public synchronized Map<String, Object> search(String query, int k) {
        if (query == null) throw new IllegalArgumentException("'q' is required");
        if (query.length() > 100) throw new IllegalArgumentException("'q' longer than 100 characters");
        if (k < 1 || k > MAX_RESULTS) throw new IllegalArgumentException("'k' must be between 1 and " + MAX_RESULTS);
        long t0 = System.nanoTime();
        List<Trie.Item<Entry>> hits = trie.search(query, k);
        long took = System.nanoTime() - t0;
        List<Map<String, Object>> items = new ArrayList<>();
        for (Trie.Item<Entry> it : hits) items.add(it.payload().toJson(it.weight()));
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("query", query);
        m.put("algorithm", "Trie (prefix tree), top-k by launches");
        m.put("tookMicros", took / 1000.0);
        m.put("catalogSize", trie.size());
        m.put("items", items);
        return m;
    }

    /** Counts a launch so the item ranks higher next time. */
    public synchronized Map<String, Object> use(String id) {
        Trie.Item<Entry> item = trie.get(id);
        if (item == null) throw new java.util.NoSuchElementException("no catalog item with id " + id);
        trie.recordUse(id);
        uses.put(id, item.weight());
        saveUses();
        return item.payload().toJson(item.weight());
    }

    public synchronized Map<String, Object> stats() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Trie (prefix tree)");
        m.put("items", trie.size());
        m.put("trieNodes", trie.nodeCount());
        m.put("itemsWithLaunches", uses.size());
        return m;
    }

    // ---- persistence --------------------------------------------------------------------

    private void loadUses() {
        Properties p = new Properties();
        try (Reader r = Files.newBufferedReader(usesFile, StandardCharsets.UTF_8)) {
            p.load(r);
        } catch (IOException ex) {
            throw new UncheckedIOException("couldn't read " + usesFile, ex);
        }
        for (String id : p.stringPropertyNames()) {
            try {
                long n = Long.parseLong(p.getProperty(id));
                if (n > 0) uses.put(id, n);
            } catch (NumberFormatException ignored) {
                // skip a damaged line
            }
        }
    }

    private void saveUses() {
        if (usesFile == null) return;
        Properties p = new Properties();
        uses.forEach((id, n) -> p.setProperty(id, Long.toString(n)));
        try {
            Path dir = usesFile.toAbsolutePath().getParent();
            if (dir != null) Files.createDirectories(dir);
            Path tmp = usesFile.resolveSibling(usesFile.getFileName() + ".tmp");
            try (Writer w = Files.newBufferedWriter(tmp, StandardCharsets.UTF_8)) {
                p.store(w, "Notchi launcher: launches per item");
            }
            Files.move(tmp, usesFile, java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                    java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException ex) {
            throw new UncheckedIOException("couldn't save launch counts", ex);
        }
    }
}
