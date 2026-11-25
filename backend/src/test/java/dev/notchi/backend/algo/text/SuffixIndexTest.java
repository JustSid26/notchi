package dev.notchi.backend.algo.text;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Random;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.*;

class SuffixIndexTest {

    @Test
    @DisplayName("edge: no documents, empty documents, empty query")
    void edges() {
        assertEquals(List.of(), new SuffixIndex(List.of()).search("a", 10));
        SuffixIndex idx = new SuffixIndex(List.of("", "abc", ""));
        assertEquals(List.of(1), idx.search("b", 10));
        assertEquals(List.of(), idx.search("", 10));
        assertEquals(0, new SuffixIndex(List.of()).count("x"));
        assertArrayEquals(new int[0], SuffixIndex.buildSuffixArray(""));
        assertArrayEquals(new int[]{0}, SuffixIndex.buildSuffixArray("z"));
    }

    @Test
    @DisplayName("suffix array of 'banana' is [5, 3, 1, 0, 4, 2]")
    void banana() {
        assertArrayEquals(new int[]{5, 3, 1, 0, 4, 2}, SuffixIndex.buildSuffixArray("banana"));
        assertArrayEquals(new int[]{3, 2, 1, 0}, SuffixIndex.buildSuffixArray("aaaa"));   // all equal characters
    }

    @Test
    @DisplayName("finds text anywhere in a document, case-insensitively")
    void substringSearch() {
        SuffixIndex idx = new SuffixIndex(List.of(
                "https://github.com/JustSid26/notchi",
                "Meeting notes: ship Notchi on Friday",
                "npm run build && npm test"));
        assertEquals(List.of(0, 1), idx.search("NOTCHI", 10));
        assertEquals(List.of(0), idx.search("sid26", 10));
        assertEquals(List.of(2), idx.search("run b", 10));
        assertEquals(List.of(), idx.search("notchy", 10));
        assertEquals(2, idx.count("npm"));
    }

    @Test
    @DisplayName("boundary: matches never span two documents, and limit caps the result")
    void noCrossDocumentMatches() {
        SuffixIndex idx = new SuffixIndex(List.of("abc", "def", "abcdef"));
        assertEquals(List.of(2), idx.search("cd", 10));     // only inside "abcdef", not across "abc"|"def"
        assertEquals(List.of(0), idx.search("abc", 1));
        assertEquals(List.of(), idx.search("c\u0000d", 10));
    }

    @Test
    @DisplayName("stress: suffix array matches a brute-force sort; search matches a scan")
    void matchesBruteForce() {
        Random r = new Random(11);
        for (int t = 0; t < 200; t++) {
            int n = r.nextInt(300);
            StringBuilder b = new StringBuilder();
            for (int i = 0; i < n; i++) b.append("abc".charAt(r.nextInt(3)));
            String s = b.toString();
            Integer[] expected = IntStream.range(0, n).boxed().toArray(Integer[]::new);
            Arrays.sort(expected, Comparator.comparing(s::substring));
            assertArrayEquals(Arrays.stream(expected).mapToInt(Integer::intValue).toArray(),
                    SuffixIndex.buildSuffixArray(s), "text " + s);
        }
        List<String> docs = new ArrayList<>();
        for (int d = 0; d < 300; d++) {
            StringBuilder b = new StringBuilder();
            int len = r.nextInt(40);
            for (int i = 0; i < len; i++) b.append("abcdE ".charAt(r.nextInt(6)));
            docs.add(b.toString());
        }
        SuffixIndex idx = new SuffixIndex(docs);
        for (int q = 0; q < 300; q++) {
            StringBuilder b = new StringBuilder();
            int len = 1 + r.nextInt(4);
            for (int i = 0; i < len; i++) b.append("abcde".charAt(r.nextInt(5)));
            String query = b.toString();
            List<Integer> scan = new ArrayList<>();
            for (int d = 0; d < docs.size(); d++) if (Kmp.contains(docs.get(d).toLowerCase(), query)) scan.add(d);
            assertEquals(scan, idx.search(query, Integer.MAX_VALUE), "query " + query);
        }
    }

    @Test
    @DisplayName("Unicode text and a separator character inside a document are handled")
    void unicode() {
        SuffixIndex idx = new SuffixIndex(List.of("café ☕ at 5", "naïve\u0000text", "日本語のテキスト"));
        assertEquals(List.of(0), idx.search("CAFÉ", 10));
        assertEquals(List.of(1), idx.search("naïve text", 10));    // the stray separator became a space
        assertEquals(List.of(2), idx.search("テキスト", 10));
    }
}
