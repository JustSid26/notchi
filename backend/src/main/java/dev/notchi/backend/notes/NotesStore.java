package dev.notchi.backend.notes;

import dev.notchi.backend.algo.text.SuffixIndex;
import dev.notchi.backend.json.Json;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.EnumMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.UUID;
import java.util.function.LongSupplier;

/**
 * Notchi's notes: each note is sorted by {@link NoteClassifier} when it's written, can be
 * searched anywhere in its text through a {@link SuffixIndex}, and reminders become due.
 *
 * <p>Secrets never reach the disk: for a note holding a password or key, only the redacted
 * text is stored (the Mac app keeps the original in the macOS Keychain).
 */
public final class NotesStore {

    public static final int MAX_NOTES = 5_000;
    public static final int MAX_LENGTH = 5_000;

    public record Note(String id, String text, NoteClassifier.Category category, double confidence,
                       List<String> reasons, List<String> urls, Long dueAt, boolean done, boolean fired,
                       boolean pinned, boolean secret, long created, long updated) {

        Note with(boolean done, boolean fired, boolean pinned, NoteClassifier.Category category, long now) {
            return new Note(id, text, category, confidence, reasons, urls, dueAt, done, fired, pinned, secret, created, now);
        }

        public Map<String, Object> toJson() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("id", id);
            m.put("text", text);
            m.put("category", category.name().toLowerCase(Locale.ROOT));
            m.put("confidence", confidence);
            m.put("reasons", reasons);
            if (!urls.isEmpty()) m.put("urls", urls);
            if (dueAt != null) m.put("dueAt", dueAt);
            m.put("done", done);
            m.put("fired", fired);
            m.put("pinned", pinned);
            m.put("secret", secret);
            m.put("created", created);
            m.put("updated", updated);
            return m;
        }
    }

    private final NoteClassifier classifier;
    private final Path file;
    private final LongSupplier clock;
    private final LinkedHashMap<String, Note> notes = new LinkedHashMap<>();
    private SuffixIndex index;
    private List<String> indexIds = List.of();

    public NotesStore(NoteClassifier classifier, Path file, LongSupplier clock) {
        this.classifier = classifier;
        this.file = file;
        this.clock = clock;
        if (file != null && Files.exists(file)) load();
    }

    /** Writes a note: classifies it, hides any secret, stores it. */
    public synchronized Note create(String text, int utcOffsetMinutes) {
        return create(null, text, utcOffsetMinutes);
    }

    /**
     * Like {@link #create(String, int)} with an id chosen by the caller (a UUID). The Mac app
     * picks the id first and puts the original text in the Keychain under it, so a lost reply
     * can never lose a secret.
     */
    public synchronized Note create(String id, String text, int utcOffsetMinutes) {
        if (id != null) {
            try {
                id = UUID.fromString(id).toString();
            } catch (IllegalArgumentException e) {
                throw new IllegalArgumentException("'id' must be a UUID");
            }
            if (notes.containsKey(id)) return notes.get(id);     // a retried request
        }
        if (text == null || text.isBlank()) throw new IllegalArgumentException("'text' must not be blank");
        if (text.length() > MAX_LENGTH) throw new IllegalArgumentException("note longer than " + MAX_LENGTH + " characters");
        if (notes.size() >= MAX_NOTES) throw new IllegalStateException("too many notes (" + MAX_NOTES + ")");
        long now = clock.getAsLong();
        String clean = text.strip();
        NoteClassifier.Result r = classifier.classify(clean, now, utcOffsetMinutes);
        boolean secret = !r.secretSpans().isEmpty();
        Note n = new Note(id != null ? id : UUID.randomUUID().toString(), secret ? r.redact(clean) : clean, r.category(),
                Math.round(r.confidence() * 100) / 100.0, r.reasons(), r.urls(), r.dueAt(),
                false, false, false, secret, now, now);
        notes.put(n.id(), n);
        changed();
        return n;
    }

    /** Marks done / fired / pinned, or moves the note to another category (your call beats ours). */
    public synchronized Note update(String id, Boolean done, Boolean fired, Boolean pinned, String category) {
        Note n = notes.get(id);
        if (n == null) throw new NoSuchElementException("no note with id " + id);
        NoteClassifier.Category cat = n.category();
        if (category != null) {
            try {
                cat = NoteClassifier.Category.valueOf(category.toUpperCase(Locale.ROOT));
            } catch (IllegalArgumentException e) {
                throw new IllegalArgumentException("unknown category '" + category + "'");
            }
        }
        Note u = n.with(done != null ? done : n.done(), fired != null ? fired : n.fired(),
                pinned != null ? pinned : n.pinned(), cat, clock.getAsLong());
        if (cat == NoteClassifier.Category.CREDENTIAL && !n.secret()) {
            // Filed as a password by hand: hide all of it (the app keeps the original in the Keychain).
            String t = n.text();
            u = new Note(u.id(), "Hidden note ••••••" + (t.length() >= 10 ? t.substring(t.length() - 2) : ""),
                    cat, u.confidence(), List.of("moved to Passwords by you"), List.of(), u.dueAt(), u.done(),
                    u.fired(), u.pinned(), true, u.created(), u.updated());
        }
        notes.put(id, u);
        changed();
        return u;
    }

    public synchronized boolean delete(String id) {
        boolean removed = notes.remove(id) != null;
        if (removed) changed();
        return removed;
    }

    /**
     * Notes, pinned first then newest. Optional filters: a category, and a query matched
     * anywhere in the text (suffix-array search).
     */
    public synchronized List<Note> list(String category, String query, int limit) {
        NoteClassifier.Category cat = null;
        if (category != null && !category.isBlank() && !category.equals("all")) {
            try {
                cat = NoteClassifier.Category.valueOf(category.toUpperCase(Locale.ROOT));
            } catch (IllegalArgumentException e) {
                throw new IllegalArgumentException("unknown category '" + category + "'");
            }
        }
        List<Note> pool;
        if (query != null && !query.isBlank()) {
            if (query.length() > 200) throw new IllegalArgumentException("query longer than 200 characters");
            ensureIndex();
            pool = new ArrayList<>();
            for (int d : index.search(query.strip(), Integer.MAX_VALUE)) pool.add(notes.get(indexIds.get(d)));
        } else {
            pool = new ArrayList<>(notes.values());
        }
        final NoteClassifier.Category filter = cat;
        return pool.stream()
                .filter(n -> filter == null || n.category() == filter)
                .sorted(Comparator.comparing(Note::pinned).reversed().thenComparing(Note::updated, Comparator.reverseOrder()))
                .limit(limit)
                .toList();
    }

    /** Reminders whose time has come and that haven't been announced or completed. */
    public synchronized List<Note> due() {
        long now = clock.getAsLong();
        return notes.values().stream()
                .filter(n -> n.dueAt() != null && n.dueAt() <= now && !n.fired() && !n.done())
                .sorted(Comparator.comparing(Note::dueAt))
                .toList();
    }

    public synchronized Map<String, Integer> counts() {
        Map<NoteClassifier.Category, Integer> c = new EnumMap<>(NoteClassifier.Category.class);
        for (Note n : notes.values()) c.merge(n.category(), 1, Integer::sum);
        Map<String, Integer> out = new LinkedHashMap<>();
        out.put("all", notes.size());
        c.forEach((k, v) -> out.put(k.name().toLowerCase(Locale.ROOT), v));
        return out;
    }

    public NoteClassifier classifier() { return classifier; }

    // ---- search index & persistence ----------------------------------------------------------

    private void changed() {
        index = null;      // rebuilt lazily on the next search
        save();
    }

    private void ensureIndex() {
        if (index != null) return;
        List<String> ids = new ArrayList<>(notes.keySet());
        List<String> texts = new ArrayList<>(ids.size());
        for (String id : ids) texts.add(notes.get(id).text());
        index = new SuffixIndex(texts);
        indexIds = ids;
    }

    private void save() {
        if (file == null) return;
        List<Object> out = new ArrayList<>();
        for (Note n : notes.values()) out.add(n.toJson());
        try {
            Path dir = file.toAbsolutePath().getParent();
            if (dir != null) Files.createDirectories(dir);
            Path tmp = file.resolveSibling(file.getFileName() + ".tmp");
            Files.writeString(tmp, Json.write(out), StandardCharsets.UTF_8);
            Files.move(tmp, file, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            throw new UncheckedIOException("couldn't save notes", e);
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
                    Note n = new Note((String) m.get("id"), (String) m.get("text"),
                            NoteClassifier.Category.valueOf(((String) m.get("category")).toUpperCase(Locale.ROOT)),
                            ((Number) m.getOrDefault("confidence", 0)).doubleValue(),
                            strings(m.get("reasons")), strings(m.get("urls")),
                            m.get("dueAt") instanceof Number d ? d.longValue() : null,
                            Boolean.TRUE.equals(m.get("done")), Boolean.TRUE.equals(m.get("fired")),
                            Boolean.TRUE.equals(m.get("pinned")), Boolean.TRUE.equals(m.get("secret")),
                            ((Number) m.get("created")).longValue(), ((Number) m.get("updated")).longValue());
                    if (n.id() != null && n.text() != null) notes.put(n.id(), n);
                } catch (RuntimeException skip) {
                    // a damaged entry shouldn't lose the rest
                }
            }
        } catch (IOException | Json.ParseException e) {
            System.err.println("[notchi-backend] couldn't read " + file + ": " + e.getMessage());
        }
    }

    private static List<String> strings(Object o) {
        List<String> out = new ArrayList<>();
        if (o instanceof List<?> l) for (Object x : l) if (x instanceof String s) out.add(s);
        return out;
    }
}
