package dev.notchi.backend.algo.tree;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

class SegmentTreeTest {

    @Test
    @DisplayName("edge: a fresh tree is all zeros; empty ranges; size 1")
    void edges() {
        SegmentTree t = new SegmentTree(1440);
        assertEquals(0, t.sum(0, 1440));
        assertEquals(0, t.max(0, 1440));
        assertEquals(0, t.sum(10, 10));
        assertEquals(-1, t.argMax(5, 5));
        SegmentTree one = new SegmentTree(1);
        one.add(0, 7);
        assertEquals(7, one.sum(0, 1));
        assertEquals(0, one.argMax(0, 1));
    }

    @Test
    @DisplayName("range sums and maxima over minute buckets")
    void sumsAndMaxima() {
        SegmentTree t = new SegmentTree(1440);
        for (int m = 540; m < 600; m++) t.add(m, 60);     // 9:00–10:00 fully active
        t.add(615, 30);                                     // half a minute at 10:15
        assertEquals(3600, t.sum(540, 600));
        assertEquals(3630, t.sum(0, 1440));
        assertEquals(30, t.sum(600, 660));
        assertEquals(60, t.max(0, 1440));
        assertEquals(30, t.max(600, 1440));
        assertEquals(540, t.argMax(0, 1440));               // first minute holding the maximum
        assertEquals(615, t.argMax(600, 700));
    }

    @Test
    @DisplayName("set overwrites; add accumulates; values can't go negative")
    void setAndAdd() {
        SegmentTree t = new SegmentTree(10);
        t.add(3, 5);
        t.add(3, 5);
        assertEquals(10, t.get(3));
        t.set(3, 2);
        assertEquals(2, t.sum(0, 10));
        assertThrows(IllegalArgumentException.class, () -> t.add(3, -3));
        assertThrows(IllegalArgumentException.class, () -> t.set(0, -1));
    }

    @Test
    @DisplayName("boundary: out-of-range indices and reversed ranges are rejected")
    void bounds() {
        SegmentTree t = new SegmentTree(10);
        assertThrows(IndexOutOfBoundsException.class, () -> t.add(10, 1));
        assertThrows(IndexOutOfBoundsException.class, () -> t.add(-1, 1));
        assertThrows(IndexOutOfBoundsException.class, () -> t.sum(0, 11));
        assertThrows(IndexOutOfBoundsException.class, () -> t.sum(5, 4));
        assertThrows(IllegalArgumentException.class, () -> new SegmentTree(0));
        assertEquals(0, t.sum(0, 10));    // non-power-of-two sizes work
    }

    @Test
    @DisplayName("stress: 20,000 random updates and queries agree with a plain array")
    void matchesArrayBaseline() {
        Random r = new Random(3);
        int n = 1000;
        SegmentTree t = new SegmentTree(n);
        long[] a = new long[n];
        for (int step = 0; step < 20_000; step++) {
            int i = r.nextInt(n);
            if (r.nextBoolean()) {
                long v = r.nextInt(61);
                t.set(i, v);
                a[i] = v;
            } else {
                int l = r.nextInt(n + 1), h = r.nextInt(n + 1);
                int lo = Math.min(l, h), hi = Math.max(l, h);
                long s = 0, m = 0;
                int arg = -1;
                for (int k = lo; k < hi; k++) {
                    s += a[k];
                    if (arg == -1 || a[k] > m) { m = a[k]; arg = k; }
                }
                assertEquals(s, t.sum(lo, hi));
                assertEquals(lo == hi ? 0 : m, t.max(lo, hi));
                assertEquals(lo == hi ? -1 : arg, t.argMax(lo, hi));
            }
        }
    }
}
