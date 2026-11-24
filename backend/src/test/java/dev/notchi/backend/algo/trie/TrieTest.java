package dev.notchi.backend.algo.trie;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

class TrieTest {

    private static List<String> labels(List<Trie.Item<String>> items) {
        return items.stream().map(Trie.Item::label).toList();
    }

    private static Trie<String> apps() {
        Trie<String> t = new Trie<>();
        t.insert("figma", "Figma", "app", 3);
        t.insert("finder", "Finder", "app", 9);
        t.insert("vsc", "Visual Studio Code", "app", 5);
        t.insert("xcode", "Xcode", "app", 1);
        t.insert("final", "Final Cut Pro", "app", 0);
        return t;
    }

    @Test
    @DisplayName("edge: empty trie and unmatched prefixes return nothing")
    void emptyAndNoMatch() {
        Trie<String> t = new Trie<>();
        assertEquals(List.of(), t.search("a", 5));
        assertEquals(List.of(), t.search("", 5));
        assertEquals(List.of(), apps().search("zzz", 5));
        assertThrows(IllegalArgumentException.class, () -> apps().search("f", 0));
        assertThrows(IllegalArgumentException.class, () -> apps().search(null, 3));
    }

    @Test
    @DisplayName("prefix search is case-insensitive and ranked by launches")
    void rankedByWeight() {
        assertEquals(List.of("Finder", "Figma", "Final Cut Pro"), labels(apps().search("FI", 5)));
        assertEquals(List.of("Finder", "Figma"), labels(apps().search("fi", 2)));   // k caps the list
    }

    @Test
    @DisplayName("every word start is searchable: 'code', 'stud', 'cut pro'")
    void matchesWordStarts() {
        Trie<String> t = apps();
        assertEquals(List.of("Visual Studio Code"), labels(t.search("stud", 5)));
        assertEquals(List.of("Visual Studio Code"), labels(t.search("code", 5)));   // not Xcode: 'code' isn't a word start there
        assertEquals(List.of("Final Cut Pro"), labels(t.search("cut pro", 5)));
        assertEquals(List.of("Final Cut Pro"), labels(t.search("  final—cut ", 5)));  // punctuation/spaces normalised
    }

    @Test
    @DisplayName("recordUse re-ranks without re-indexing; ties break alphabetically")
    void recordUseAndTies() {
        Trie<String> t = new Trie<>();
        t.insert("b", "Bear", "app", 0);
        t.insert("a", "Beeper", "app", 0);
        assertEquals(List.of("Bear", "Beeper"), labels(t.search("be", 5)));        // tie → A–Z
        t.recordUse("a");
        assertEquals(List.of("Beeper", "Bear"), labels(t.search("be", 5)));
        assertThrows(IllegalArgumentException.class, () -> t.recordUse("missing"));
        Trie<String> mixed = new Trie<>();
        mixed.insert("1", "iTerm", null, 0);
        mixed.insert("2", "Zoom", null, 0);
        mixed.insert("3", "arc", null, 0);
        assertEquals(List.of("arc", "iTerm", "Zoom"), labels(mixed.search("", 5)));   // A–Z ignoring case
    }

    @Test
    @DisplayName("validation: duplicate ids, blank or symbol-only labels, negative weight")
    void validation() {
        Trie<String> t = apps();
        assertThrows(IllegalArgumentException.class, () -> t.insert("figma", "Figma 2", "app", 0));
        assertThrows(IllegalArgumentException.class, () -> t.insert("x", "   ", "app", 0));
        assertThrows(IllegalArgumentException.class, () -> t.insert("y", "!!!", "app", 0));
        assertThrows(IllegalArgumentException.class, () -> t.insert("z", "Zed", "app", -1));
        assertThrows(IllegalArgumentException.class, () -> t.insert("long", "x".repeat(121), "app", 0));
        assertThrows(IllegalArgumentException.class, () -> t.insert("rocket", "🚀", "tab", 0));   // no letters
        t.insert("math", "𝐀𝐁 Notes", "app", 0);           // letters outside the BMP still count
        assertEquals(List.of("𝐀𝐁 Notes"), labels(t.search("𝐀", 5)));
        assertEquals(List.of("𝐀𝐁 Notes"), labels(t.search("not", 5)));
    }

    @Test
    @DisplayName("remove deletes the item and prunes its now-empty nodes")
    void removePrunes() {
        Trie<String> t = new Trie<>();
        t.insert("a", "Alpha", null, 0);
        long nodesWithAlpha = t.nodeCount();
        t.insert("b", "Alpine Beta", null, 0);
        assertTrue(t.remove("b"));
        assertFalse(t.remove("b"));
        assertEquals(nodesWithAlpha, t.nodeCount());
        assertEquals(t.countNodesSlow(), t.nodeCount());
        assertEquals(List.of("Alpha"), labels(t.search("al", 5)));
        assertEquals(List.of(), t.search("beta", 5));
    }

    @Test
    @DisplayName("stress: 3,000 random labels — trie search equals the linear-scan baseline")
    void matchesLinearBaseline() {
        Random rnd = new Random(7);
        String[] words = {"code", "studio", "final", "cut", "fig", "finder", "note", "notion", "term", "tab",
                "claude", "craft", "crm", "docs", "dock", "music", "mail", "maps", "pro", "x"};
        Trie<String> t = new Trie<>();
        for (int i = 0; i < 3000; i++) {
            int n = 1 + rnd.nextInt(3);
            List<String> w = new ArrayList<>();
            for (int j = 0; j < n; j++) w.add(words[rnd.nextInt(words.length)]);
            t.insert("id" + i, String.join(" ", w), null, rnd.nextInt(50));
        }
        for (int q = 0; q < 300; q++) {
            String word = words[rnd.nextInt(words.length)];
            String prefix = word.substring(0, 1 + rnd.nextInt(word.length()));
            assertEquals(Trie.linearSearch(t.items(), prefix, 8).stream().map(Trie.Item::id).toList(),
                    t.search(prefix, 8).stream().map(Trie.Item::id).toList(), "prefix " + prefix);
        }
        assertEquals(t.countNodesSlow(), t.nodeCount());
    }
}
