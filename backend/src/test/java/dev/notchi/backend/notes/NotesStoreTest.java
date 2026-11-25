package dev.notchi.backend.notes;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.*;

class NotesStoreTest {

    private final AtomicLong now = new AtomicLong(1_795_000_000_000L);

    @Test
    @DisplayName("secrets are redacted before anything is stored or saved")
    void secretsNeverStored(@TempDir Path dir) throws Exception {
        NotesStore s = new NotesStore(new NoteClassifier(), dir.resolve("notes.json"), now::get);
        NotesStore.Note n = s.create("aws secret: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", 0);
        assertTrue(n.secret());
        assertFalse(n.text().contains("wJalrXUtnFEMI"));
        assertFalse(Files.readString(dir.resolve("notes.json")).contains("wJalrXUtnFEMI"));
        assertEquals(List.of(), s.list(null, "wJalr", 10));      // and the secret isn't searchable
    }

    @Test
    @DisplayName("search finds text anywhere; category filter; pinned first")
    void searchAndFilter() {
        NotesStore s = new NotesStore(new NoteClassifier(), null, now::get);
        NotesStore.Note link = s.create("https://github.com/JustSid26/notchi", 0);
        now.addAndGet(1000);
        s.create("buy milk and eggs", 0);
        now.addAndGet(1000);
        s.create("milkshake recipe idea", 0);
        assertEquals(2, s.list(null, "MILK", 10).size());
        assertEquals(List.of(link.id()), s.list(null, "sid26", 10).stream().map(NotesStore.Note::id).toList());
        assertEquals(1, s.list("todo", null, 10).size());
        s.update(link.id(), null, null, true, null);
        assertEquals(link.id(), s.list(null, null, 10).get(0).id());
        assertThrows(IllegalArgumentException.class, () -> s.list("robots", null, 10));
    }

    @Test
    @DisplayName("reminders become due once, and you can re-file a note")
    void dueAndUpdate() {
        NotesStore s = new NotesStore(new NoteClassifier(), null, now::get);
        NotesStore.Note r = s.create("standup in 20 min", 0);
        assertEquals(List.of(), s.due());
        now.addAndGet(21 * 60_000);
        assertEquals(1, s.due().size());
        s.update(r.id(), null, true, null, null);
        assertEquals(List.of(), s.due());
        assertEquals(NoteClassifier.Category.TODO, s.update(r.id(), null, null, null, "todo").category());
        assertThrows(NoSuchElementException.class, () -> s.update("missing", true, null, null, null));
        assertThrows(IllegalArgumentException.class, () -> s.update(r.id(), null, null, null, "robots"));
    }

    @Test
    @DisplayName("a client-chosen id is kept (and a retry returns the same note); filing as Passwords hides it")
    void clientIdAndManualPassword() {
        NotesStore s = new NotesStore(new NoteClassifier(), null, now::get);
        String id = "0b8f7e9c-1d2a-4c3b-9e8f-112233445566";
        NotesStore.Note n = s.create(id, "door code 4415 at the back gate", 0);
        assertEquals(id, n.id());
        assertSame(n, s.create(id, "door code 4415 at the back gate", 0));
        assertThrows(IllegalArgumentException.class, () -> s.create("not-a-uuid", "x", 0));
        NotesStore.Note hidden = s.update(id, null, null, null, "credential");
        assertTrue(hidden.secret());
        assertFalse(hidden.text().contains("4415"));
        assertEquals(List.of(), s.list(null, "4415", 10));
    }

    @Test
    @DisplayName("boundary: blank and over-long notes are rejected; notes survive a restart")
    void validationAndPersistence(@TempDir Path dir) {
        NotesStore s = new NotesStore(new NoteClassifier(), dir.resolve("notes.json"), now::get);
        assertThrows(IllegalArgumentException.class, () -> s.create("  ", 0));
        assertThrows(IllegalArgumentException.class, () -> s.create("x".repeat(NotesStore.MAX_LENGTH + 1), 0));
        NotesStore.Note n = s.create("buy milk", 0);
        assertTrue(s.delete(n.id()));
        assertFalse(s.delete(n.id()));
        s.create("call mom tomorrow", 0);
        NotesStore reloaded = new NotesStore(new NoteClassifier(), dir.resolve("notes.json"), now::get);
        assertEquals(1, reloaded.list(null, null, 10).size());
        assertEquals("call mom tomorrow", reloaded.list(null, "mom", 10).get(0).text());
    }
}
