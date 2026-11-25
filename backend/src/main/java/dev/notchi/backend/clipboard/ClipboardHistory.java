package dev.notchi.backend.clipboard;

import dev.notchi.backend.algo.text.SuffixIndex;
import dev.notchi.backend.json.Json;
import dev.notchi.backend.notes.NoteClassifier;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.UUID;
import java.util.function.LongSupplier;

/**
 * Clipboard history: the last {@value #MAX_CLIPS} things you copied, newest first.
 *
 * <ul>
 *   <li>Copying the same text again moves it to the top instead of adding a second copy
 *       (an exact hash map from text to clip; the history is capped, so an exact map is
 *       small and a Bloom filter wouldn't save anything here).</li>
 *   <li>Every clip is sorted by {@link NoteClassifier} (link, code, contact…). Anything
 *       that looks like a password or key is <b>not stored</b> at all.</li>
 *   <li>Search finds text anywhere inside a clip, using a {@link SuffixIndex} that is rebuilt
 *       lazily after the history changes.</li>
 * </ul>
 */
public final class ClipboardHistory {

    public static final int MAX_CLIPS = 500;
    public static final int MAX_LENGTH = 20_000;
    /** Only the start of a very long clip is searchable, to keep the index small. */
    static final int INDEXED_CHARS = 4_000;

    public enum Status { ADDED, MERGED, SKIPPED_SECRET }

    public record Clip(String id, String text, NoteClassifier.Category kind, String source, long firstSeen,
                       long lastSeen, int copies, boolean pinned) {
        public Map<String, Object> toJson() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", id);
            m.put("text", text);
            m.put("kind", kind.name().toLowerCase(Locale.ROOT));
            if (source != null) m.put("source", source);
            m.put("firstSeen", firstSeen);
            m.put("lastSeen", lastSeen);
            m.put("copies", copies);
            m.put("pinned", pinned);
            return m;
        }
    }

    public record Result(Status status, Clip clip) {}

    private final NoteClassifier classifier;
    private final Path file;
    private final LongSupplier clock;
    /** Oldest first: re-inserting on every copy keeps the order by last use. */
    private final LinkedHashMap<String, Clip> clips = new LinkedHashMap<>();
    private final Map<String, String> idByText = new HashMap<>();
    private SuffixIndex index;
    private List<String> indexIds = List.of();
    private long skippedSecrets, merged;

    public ClipboardHistory(NoteClassifier classifier, Path file, LongSupplier clock) {
        this.classifier = classifier;
        this.file = file;
        this.clock = clock;
        if (file != null && Files.exists(file)) load();
    }

    public synchronized Result add(String text, String source) {
        if (text == null || text.isBlank()) throw new IllegalArgumentException("'text' must not be blank");
        if (text.length() > MAX_LENGTH) throw new IllegalArgumentException("clip longer than " + MAX_LENGTH + " characters");
        if (source != null && source.length() > 200) throw new IllegalArgumentException("'source' longer than 200 characters");
        long now = clock.getAsLong();
        NoteClassifier.Result r = classifier.classify(text, now, 0);
        if (!r.secretSpans().isEmpty()) {
            skippedSecrets++;
            return new Result(Status.SKIPPED_SECRET, null);
        }
        String existing = idByText.get(text);
        if (existing != null) {
            Clip old = clips.remove(existing);
            Clip bumped = new Clip(old.id(), old.text(), old.kind(), source != null ? source : old.source(),
                    old.firstSeen(), now, old.copies() + 1, old.pinned());
            clips.put(old.id(), bumped);
            merged++;
            changed();
            return new Result(Status.MERGED, bumped);
        }
        Clip c = new Clip(UUID.randomUUID().toString(), text, r.category(), source, now, now, 1, false);
        clips.put(c.id(), c);
        idByText.put(text, c.id());
        evict();
        changed();
        return new Result(Status.ADDED, c);
    }

    /** Newest first (pinned clips stay on top). With a query: only clips containing it. */
    public synchronized List<Clip> list(String query, int limit) {
        List<Clip> pool;
        if (query != null && !query.isBlank()) {
            if (query.length() > 200) throw new IllegalArgumentException("query longer than 200 characters");
            ensureIndex();
            pool = new ArrayList<>();
            for (int d : index.search(query, Integer.MAX_VALUE)) pool.add(clips.get(indexIds.get(d)));
        } else {
            pool = new ArrayList<>(clips.values());
        }
        pool.sort((a, b) -> a.pinned() != b.pinned() ? (a.pinned() ? -1 : 1) : Long.compare(b.lastSeen(), a.lastSeen()));
        return pool.size() > limit ? pool.subList(0, limit) : pool;
    }

    public synchronized Clip pin(String id, boolean pinned) {
        Clip c = clips.get(id);
        if (c == null) throw new NoSuchElementException("no clip with id " + id);
        Clip p = new Clip(c.id(), c.text(), c.kind(), c.source(), c.firstSeen(), c.lastSeen(), c.copies(), pinned);
        clips.put(id, p);
        changed();
        return p;
    }

    public synchronized boolean delete(String id) {
        Clip c = clips.remove(id);
        if (c == null) return false;
        idByText.remove(c.text());
        changed();
        return true;
    }

    /** Clears the history; pinned clips stay unless {@code everything}. Returns how many went. */
    public synchronized int clear(boolean everything) {
        int before = clips.size();
        clips.values().removeIf(c -> everything || !c.pinned());
        idByText.clear();
        for (Clip c : clips.values()) idByText.put(c.text(), c.id());
        changed();
        return before - clips.size();
    }

    public synchronized Map<String, Object> stats() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Suffix array search (prefix doubling + radix sort)");
        m.put("clips", clips.size());
        m.put("repeatsMerged", merged);
        m.put("secretsSkipped", skippedSecrets);
        m.put("indexedCharacters", index == null ? 0 : index.length());
        return m;
    }

    // ---- internals ------------------------------------------------------------------------------

    /** Drops the least recently copied unpinned clips beyond the cap. */
    private void evict() {
        var it = clips.values().iterator();
        while (clips.size() > MAX_CLIPS && it.hasNext()) {
            Clip c = it.next();
            if (c.pinned()) continue;
            it.remove();
            idByText.remove(c.text());
        }
    }

    private void changed() {
        index = null;
        save();
    }

    private void ensureIndex() {
        if (index != null) return;
        List<String> ids = new ArrayList<>(clips.keySet());
        List<String> texts = new ArrayList<>(ids.size());
        for (String id : ids) {
            String t = clips.get(id).text();
            texts.add(t.length() > INDEXED_CHARS ? t.substring(0, INDEXED_CHARS) : t);
        }
        index = new SuffixIndex(texts);
        indexIds = ids;
    }

    private void save() {
        if (file == null) return;
        List<Object> out = new ArrayList<>();
        for (Clip c : clips.values()) out.add(c.toJson());
        try {
            Path dir = file.toAbsolutePath().getParent();
            if (dir != null) Files.createDirectories(dir);
            Path tmp = file.resolveSibling(file.getFileName() + ".tmp");
            Files.writeString(tmp, Json.write(out), StandardCharsets.UTF_8);
            Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            throw new UncheckedIOException("couldn't save clipboard history", e);
        }
    }

    @SuppressWarnings("unchecked")
    private void load() {
        try {
            Object parsed = Json.parse(Files.readString(file, StandardCharsets.UTF_8));
            if (!(parsed instanceof List<?> list)) return;
            for (Object o : list) {
                if (!(o instanceof Map<?, ?> raw)) continue;
                Map<String, Object> m = (Map<String, Object>) raw;
                try {
                    Clip c = new Clip((String) m.get("id"), (String) m.get("text"),
                            NoteClassifier.Category.valueOf(((String) m.get("kind")).toUpperCase(Locale.ROOT)),
                            (String) m.get("source"), ((Number) m.get("firstSeen")).longValue(),
                            ((Number) m.get("lastSeen")).longValue(), ((Number) m.get("copies")).intValue(),
                            Boolean.TRUE.equals(m.get("pinned")));
                    if (c.id() != null && c.text() != null && !idByText.containsKey(c.text())) {
                        clips.put(c.id(), c);
                        idByText.put(c.text(), c.id());
                    }
                } catch (RuntimeException skip) {
                    // ignore a damaged entry
                }
            }
        } catch (IOException | Json.ParseException e) {
            System.err.println("[notchi-backend] couldn't read " + file + ": " + e.getMessage());
        }
    }

    /** Package-private for tests. */
    int size() { return clips.size(); }

}
