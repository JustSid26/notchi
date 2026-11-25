package dev.notchi.backend.notes;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;

import static dev.notchi.backend.notes.NoteClassifier.Category.*;
import static org.junit.jupiter.api.Assertions.*;

class NoteClassifierTest {

    private static final ZoneOffset IST = ZoneOffset.ofHoursMinutes(5, 30);
    /** Wednesday 25 Nov 2026, 10:00 in India. */
    private static final long NOW = LocalDateTime.of(2026, 11, 25, 10, 0).toInstant(IST).toEpochMilli();
    private final NoteClassifier c = new NoteClassifier();

    private NoteClassifier.Result r(String text) { return c.classify(text, NOW, 330); }

    private static LocalDateTime local(Long millis) {
        return LocalDateTime.ofInstant(Instant.ofEpochMilli(millis), IST);
    }

    @Test
    @DisplayName("passwords and keys: detected, and the secret part is hidden")
    void credentials() {
        assertEquals(CREDENTIAL, r("netflix password: hunter2").category());
        assertEquals("netflix password: ••••••", r("netflix password: hunter2").redact("netflix password: hunter2"));
        assertEquals("my wifi password is ••••••22", r("my wifi password is Blue#Sky22").redact("my wifi password is Blue#Sky22"));
        String key = "deploy with ghp_8f2KxQ1zP0aBcD9eF7gH3iJ5kL";
        assertEquals(CREDENTIAL, r(key).category());
        assertFalse(r(key).redact(key).contains("8f2KxQ1"));
        String pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----";
        assertEquals("••••••--", r(pem).redact(pem));
    }

    @Test
    @DisplayName("passphrases, 'is', URLs and lone passwords: the whole secret is hidden and nothing leaks")
    void reviewedLeaks() {
        String pass = "wifi password: correct horse battery staple";
        assertFalse(r(pass).redact(pass).contains("horse"));
        String code = "recovery code: 1234 5678 9012";
        assertFalse(r(code).redact(code).contains("5678"));
        assertTrue(r(code).phones().isEmpty());                       // no "phone: 1234 5678 9012"
        assertTrue(r(code).reasons().stream().noneMatch(s -> s.contains("1234")));
        String is = "wifi password is bluemoon";
        assertEquals(CREDENTIAL, r(is).category());
        assertFalse(r(is).redact(is).contains("bluemoon"));
        String url = "https://bob:hunter2@example.com/admin?access_token=ghp_8f2KxQ1zP0aBcD9eF7gH3iJ5kL";
        assertFalse(r(url).redact(url).contains("hunter2"));
        assertFalse(r(url).redact(url).contains("8f2KxQ1"));
        assertTrue(r(url).urls().isEmpty());                          // the raw URL isn't kept
        assertEquals(CREDENTIAL, r("Tr0ub4dor&3").category());
        assertEquals(NOTE, r("password manager is great").category());
        assertEquals(NOTE, r("report_final2.pdf").category());
        assertEquals(NOTE, r("the key is to stay calm").category());
    }

    @Test
    @DisplayName("credential words without a secret are just notes (no false alarms)")
    void noFalseCredentials() {
        assertEquals(NOTE, r("the secret to good coffee is fresh beans").category());
        assertEquals(NOTE, r("pin the tab to the island").category());
        assertEquals(NOTE, r("550e8400-e29b-41d4-a716-446655440000").category());   // a UUID isn't a key or a phone
        assertFalse(r("sk-learn-tutorial notes").secretSpans().size() > 0);
    }

    @Test
    @DisplayName("reminders: due times are resolved in the user's time zone")
    void reminders() {
        NoteClassifier.Result a = r("remind me to call mom tomorrow at 5pm");
        assertEquals(REMINDER, a.category());
        assertEquals(LocalDateTime.of(2026, 11, 26, 17, 0), local(a.dueAt()));
        assertEquals(LocalDateTime.of(2026, 11, 27, 9, 30), local(r("dentist appointment friday 9:30am").dueAt()));
        assertEquals(LocalDateTime.of(2026, 11, 25, 10, 20), local(r("standup in 20 min").dueAt()));
        assertEquals(LocalDateTime.of(2026, 11, 25, 13, 0), local(r("lunch with priya at 1").dueAt()));
        assertEquals(LocalDateTime.of(2026, 11, 26, 9, 0), local(r("call the bank at 9am").dueAt()));   // 9 am already passed today
        assertEquals(LocalDateTime.of(2026, 11, 25, 20, 0), local(r("watch the match tonight").dueAt()));
        assertNull(r("buy 5 apples").dueAt());                                                         // "5" alone isn't a time
        assertNull(r("buy milk 2.49").dueAt());                                                        // a price isn't a time
        assertNull(r("upgrade to python 3.12").dueAt());
        assertEquals(LocalDateTime.of(2026, 11, 25, 17, 30), local(r("call mom at 5:30").dueAt()));  // afternoon
        assertEquals(LocalDateTime.of(2026, 11, 25, 15, 0), local(r("standup wednesday 3pm").dueAt())); // today's weekday counts
        assertEquals(LocalDateTime.of(2026, 12, 2, 9, 30), local(r("standup wednesday 9:30am").dueAt())); // …unless it has passed
    }

    @Test
    @DisplayName("links, contacts, to-dos, code and ideas")
    void otherCategories() {
        assertEquals(LINK, r("https://github.com/JustSid26/notchi").category());
        assertEquals(LINK, r("notchi.app/download").category());
        NoteClassifier.Result contact = r("Rahul +91 98765 43210 rahul@gmail.com");
        assertEquals(CONTACT, contact.category());
        assertEquals("+91 98765 43210", contact.phones().get(0));
        assertEquals("rahul@gmail.com", contact.emails().get(0));
        assertEquals(TODO, r("buy milk and eggs").category());
        assertEquals(TODO, r("todo: fix login bug").category());
        assertEquals(CODE, r("npm run build && npm test").category());
        assertEquals(CODE, r("def add(a, b):\n    return a + b").category());
        assertEquals(IDEA, r("idea: an app that turns your notch into a pet").category());
    }

    @Test
    @DisplayName("'today' with no time, said late in the day, is due soon rather than in the past")
    void todayLater() {
        long fivePm = LocalDateTime.of(2026, 11, 25, 17, 0).toInstant(IST).toEpochMilli();
        Long due = c.classify("finish the report today", fivePm, 330).dueAt();
        assertEquals(LocalDateTime.of(2026, 11, 25, 18, 0), local(due));
        assertEquals(NOTE, r("Got a letter from the bank about where to send the forms").category());
    }

    @Test
    @DisplayName("boundary: empty text, plain text, and over-long input")
    void boundaries() {
        assertEquals(NOTE, r("").category());
        assertEquals(NOTE, r("meeting notes from the design review").category());
        assertThrows(IllegalArgumentException.class, () -> r("x".repeat(NoteClassifier.MAX_LENGTH + 1)));
        assertThrows(IllegalArgumentException.class, () -> c.classify(null, NOW, 0));
        assertTrue(r("buy milk").confidence() > 0 && r("buy milk").confidence() <= 1);
    }

    @Test
    @DisplayName("the verdict explains itself (reasons) and matches only whole words")
    void reasonsAndWordBoundaries() {
        assertTrue(r("buy milk tomorrow").reasons().stream().anyMatch(s -> s.contains("buy")));
        assertTrue(r("buy milk tomorrow").reasons().stream().anyMatch(s -> s.contains("time found")));
        assertEquals(NOTE, r("bypass the passport office").category());   // "pass" inside other words doesn't count
        assertEquals(NOTE, r("everyday life").category());                 // "day" isn't a cue; "every" isn't "eve"
    }
}
