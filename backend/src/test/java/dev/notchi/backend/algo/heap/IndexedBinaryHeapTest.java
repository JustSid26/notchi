package dev.notchi.backend.algo.heap;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

class IndexedBinaryHeapTest {

    private static IndexedBinaryHeap<String, Integer> maxHeap() {
        return new IndexedBinaryHeap<>(Comparator.naturalOrder());
    }

    @Test
    @DisplayName("edge: empty heap — peek/poll throw, topK is empty, remove returns null")
    void emptyHeap() {
        var h = maxHeap();
        assertTrue(h.isEmpty());
        assertThrows(NoSuchElementException.class, h::peek);
        assertThrows(NoSuchElementException.class, h::poll);
        assertEquals(List.of(), h.topK(5));
        assertNull(h.remove("missing"));
        assertThrows(IllegalArgumentException.class, () -> h.topK(-1));
    }

    @Test
    @DisplayName("edge: a single element is both the top and the last")
    void singleElement() {
        var h = maxHeap();
        h.push("a", 7);
        assertEquals("a", h.peek().getKey());
        assertEquals(7, h.poll().getValue());
        assertTrue(h.isEmpty());
        assertTrue(h.isValid());
    }

    @Test
    @DisplayName("poll returns elements in descending priority (heap sort property)")
    void pollsInPriorityOrder() {
        var h = maxHeap();
        int[] values = {5, 3, 9, 1, 9, 7, 2, 8, 6, 4};
        for (int i = 0; i < values.length; i++) h.push("k" + i, values[i]);
        assertTrue(h.isValid());
        List<Integer> out = new ArrayList<>();
        while (!h.isEmpty()) out.add(h.poll().getValue());
        assertEquals(List.of(9, 9, 8, 7, 6, 5, 4, 3, 2, 1), out);
    }

    @Test
    @DisplayName("update moves an element up or down; duplicate push is rejected")
    void updateAndDuplicateKeys() {
        var h = maxHeap();
        h.push("build", 2);
        h.push("deploy", 5);
        h.push("tests", 3);
        h.update("build", 10);                  // increase-key → new top
        assertEquals("build", h.peek().getKey());
        h.update("build", 1);                   // decrease-key → sinks
        assertEquals("deploy", h.peek().getKey());
        assertTrue(h.isValid());
        assertThrows(IllegalArgumentException.class, () -> h.push("deploy", 1));
        assertThrows(NoSuchElementException.class, () -> h.update("nope", 1));
        assertFalse(h.upsert("deploy", 0));     // existing → update
        assertTrue(h.upsert("lint", 4));        // new → push
        assertEquals("lint", h.peek().getKey());
    }

    @Test
    @DisplayName("remove(key) from the middle keeps both invariants")
    void removeFromMiddle() {
        var h = maxHeap();
        for (int i = 0; i < 50; i++) h.push("k" + i, (i * 37) % 50);
        assertEquals((7 * 37) % 50, h.remove("k7"));
        assertFalse(h.contains("k7"));
        assertEquals(49, h.size());
        assertTrue(h.isValid());
    }

    @Test
    @DisplayName("topK is sorted, doesn't modify the heap, and handles k > size")
    void topK() {
        var h = maxHeap();
        for (int i = 0; i < 20; i++) h.push("k" + i, (i * 7) % 20);
        List<Map.Entry<String, Integer>> top = h.topK(5);
        assertEquals(List.of(19, 18, 17, 16, 15), top.stream().map(Map.Entry::getValue).toList());
        assertEquals(20, h.size());
        assertTrue(h.isValid());
        assertEquals(20, h.topK(100).size());
        assertEquals(List.of(), h.topK(0));
    }

    @Test
    @DisplayName("stress: 20,000 random operations agree with a brute-force reference")
    void randomOperationsMatchReference() {
        var h = maxHeap();
        Map<String, Integer> ref = new HashMap<>();
        Random rnd = new Random(42);
        for (int step = 0; step < 20_000; step++) {
            String key = "k" + rnd.nextInt(300);
            int op = rnd.nextInt(4);
            if (op == 0) {
                int v = rnd.nextInt(1000);
                h.upsert(key, v);
                ref.put(key, v);
            } else if (op == 1) {
                assertEquals(ref.remove(key), h.remove(key));
            } else if (op == 2 && !ref.isEmpty()) {
                int best = ref.values().stream().max(Integer::compare).orElseThrow();
                assertEquals(best, h.peek().getValue());
            } else if (!ref.isEmpty()) {
                List<Integer> expected = ref.values().stream().sorted(Comparator.reverseOrder()).limit(10).toList();
                assertEquals(expected, h.topK(10).stream().map(Map.Entry::getValue).toList());
            }
            assertEquals(ref.size(), h.size());
        }
        assertTrue(h.isValid());
    }
}
