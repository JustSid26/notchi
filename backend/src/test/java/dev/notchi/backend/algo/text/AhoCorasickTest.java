package dev.notchi.backend.algo.text;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

class AhoCorasickTest {

    private static List<String> found(AhoCorasick<String> ac, String text) {
        return ac.findAll(text).stream().map(m -> m.pattern() + "@" + m.start()).toList();
    }

    @Test
    @DisplayName("edge: no patterns, empty text, and use before build")
    void edges() {
        AhoCorasick<String> empty = new AhoCorasick<String>().build();
        assertEquals(List.of(), empty.findAll("anything"));
        AhoCorasick<String> ac = new AhoCorasick<String>().add("a", "x").build();
        assertEquals(List.of(), ac.findAll(""));
        assertThrows(IllegalStateException.class, () -> new AhoCorasick<String>().add("a", "x").findAll("a"));
        assertThrows(IllegalArgumentException.class, () -> new AhoCorasick<String>().add("", "x"));
        assertThrows(IllegalStateException.class, () -> ac.add("b", "y"));
    }

    @Test
    @DisplayName("the classic example: he, she, his, hers in 'ushers'")
    void classicExample() {
        AhoCorasick<String> ac = new AhoCorasick<String>()
                .add("he", "").add("she", "").add("his", "").add("hers", "").build();
        assertEquals(List.of("she@1", "he@2", "hers@2"), found(ac, "ushers"));
    }

    @Test
    @DisplayName("overlapping and nested patterns are all reported (via output links)")
    void overlapping() {
        AhoCorasick<String> ac = new AhoCorasick<String>().add("a", "").add("aa", "").add("aaa", "").build();
        assertEquals(List.of("a@0", "aa@0", "a@1", "aaa@0", "aa@1", "a@2"), found(ac, "aaa"));
    }

    @Test
    @DisplayName("case-insensitive, and payloads come back with each match")
    void caseAndPayload() {
        AhoCorasick<Integer> ac = new AhoCorasick<Integer>().add("Password", 3).add("https://", 5).build();
        var m = ac.findAll("My PASSWORD is at HTTPS://x.dev");
        assertEquals(2, m.size());
        assertEquals(3, m.get(0).payload());
        assertEquals(3, m.get(0).start());
        assertEquals(11, m.get(0).end());
        assertEquals(5, m.get(1).payload());
    }

    @Test
    @DisplayName("stress: 300 random texts × 40 random patterns agree with KMP run per pattern")
    void matchesKmpBaseline() {
        Random r = new Random(5);
        for (int t = 0; t < 300; t++) {
            List<String> pats = new ArrayList<>();
            AhoCorasick<String> ac = new AhoCorasick<>();
            for (int i = 0; i < 40; i++) {
                String p = randomString(r, 1 + r.nextInt(4), "abc");
                pats.add(p);
                ac.add(p, p);
            }
            ac.build();
            String text = randomString(r, r.nextInt(200), "abcd");
            long expected = 0;
            for (String p : pats) expected += Kmp.findAll(text, p).size();
            assertEquals(expected, ac.findAll(text).size());
            for (var m : ac.findAll(text)) assertEquals(m.pattern(), text.substring(m.start(), m.end()));
        }
    }

    @Test
    @DisplayName("KMP prefix function and search (the baseline)")
    void kmp() {
        assertArrayEquals(new int[]{0, 0, 1, 0, 1, 2, 3}, Kmp.prefixFunction("abacaba"));
        assertEquals(List.of(0, 1, 2, 3, 4), Kmp.findAll("aaaaaa", "aa"));    // overlapping
        assertEquals(List.of(1, 3), Kmp.findAll("xababab", "abab"));
        assertTrue(Kmp.contains("notchi island", "island"));
        assertFalse(Kmp.contains("notchi", "notchy"));
        assertThrows(IllegalArgumentException.class, () -> Kmp.findAll("abc", ""));
    }

    private static String randomString(Random r, int len, String alphabet) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < len; i++) b.append(alphabet.charAt(r.nextInt(alphabet.length())));
        return b.toString();
    }
}
