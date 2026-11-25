package dev.notchi.backend.clipboard;

import dev.notchi.backend.notes.NoteClassifier;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

import static dev.notchi.backend.clipboard.ClipboardHistory.Status.*;
import static org.junit.jupiter.api.Assertions.*;

class ClipboardHistoryTest {

    private final AtomicLong now = new AtomicLong(1_000);

    private ClipboardHistory history() {
        return new ClipboardHistory(new NoteClassifier(), null, () -> now.addAndGet(10));
    }

    private static List<String> texts(List<ClipboardHistory.Clip> clips) {
        return clips.stream().map(ClipboardHistory.Clip::text).toList();
    }

    @Test
    @DisplayName("newest first; copying something again moves it to the top instead of duplicating")
    void orderAndRepeats() {
        ClipboardHistory h = history();
        assertEquals(ADDED, h.add("first", "Notes").status());
        h.add("second", null);
        ClipboardHistory.Result again = h.add("first", "Safari");
        assertEquals(MERGED, again.status());
        assertEquals(2, again.clip().copies());
        assertEquals(List.of("first", "second"), texts(h.list(null, 10)));
        assertEquals("Safari", h.list(null, 10).get(0).source());
    }

    @Test
    @DisplayName("passwords and keys are never stored")
    void secretsSkipped() {
        ClipboardHistory h = history();
        assertEquals(SKIPPED_SECRET, h.add("ghp_8f2KxQ1zP0aBcD9eF7gH3iJ5kL", null).status());
        assertEquals(SKIPPED_SECRET, h.add("password: hunter2", null).status());
        assertEquals(0, h.size());
        assertEquals(2L, h.stats().get("secretsSkipped"));
    }

    @Test
    @DisplayName("search matches text anywhere in a clip, case-insensitively")
    void search() {
        ClipboardHistory h = history();
        h.add("https://github.com/JustSid26/notchi", null);
        h.add("npm run build && npm test", null);
        h.add("Notchi island notes", null);
        assertEquals(List.of("Notchi island notes", "https://github.com/JustSid26/notchi"), texts(h.list("NOTCHI", 10)));
        assertEquals(List.of("npm run build && npm test"), texts(h.list("build &&", 10)));
        assertEquals(List.of(), texts(h.list("nothing like this", 10)));
        h.add("build && deploy", null);                 // the index is rebuilt after a change
        assertEquals(2, h.list("build &&", 10).size());
    }

    @Test
    @DisplayName("boundary: the history is capped; pinned clips survive eviction and clearing")
    void capPinAndClear() {
        ClipboardHistory h = history();
        ClipboardHistory.Clip keep = h.add("keep me", null).clip();
        h.pin(keep.id(), true);
        for (int i = 0; i < ClipboardHistory.MAX_CLIPS + 50; i++) h.add("clip " + i, null);
        assertEquals(ClipboardHistory.MAX_CLIPS, h.size());
        assertEquals("keep me", h.list(null, 1).get(0).text());       // pinned stays on top
        assertEquals(ClipboardHistory.MAX_CLIPS - 1, h.clear(false));
        assertEquals(List.of("keep me"), texts(h.list(null, 10)));
        assertThrows(IllegalArgumentException.class, () -> h.add(" ", null));
        assertThrows(IllegalArgumentException.class, () -> h.add("x".repeat(ClipboardHistory.MAX_LENGTH + 1), null));
    }

    @Test
    @DisplayName("history is saved and reloaded, and each clip is sorted (link, code…)")
    void persistenceAndKinds(@TempDir Path dir) {
        ClipboardHistory h = new ClipboardHistory(new NoteClassifier(), dir.resolve("clips.json"), () -> now.addAndGet(10));
        h.add("https://example.com/report", null);
        h.add("git push origin main", null);
        ClipboardHistory again = new ClipboardHistory(new NoteClassifier(), dir.resolve("clips.json"), () -> now.addAndGet(10));
        List<ClipboardHistory.Clip> clips = again.list(null, 10);
        assertEquals(2, clips.size());
        assertEquals(NoteClassifier.Category.CODE, clips.get(0).kind());
        assertEquals(NoteClassifier.Category.LINK, clips.get(1).kind());
        assertEquals(MERGED, again.add("git push origin main", null).status());
    }
}
