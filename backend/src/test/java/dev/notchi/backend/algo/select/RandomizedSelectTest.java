package dev.notchi.backend.algo.select;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.Arrays;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

class RandomizedSelectTest {

    private static RandomizedSelect seeded() { return new RandomizedSelect(new Random(1)); }

    @Test
    @DisplayName("edge: one element, and invalid input (empty, NaN, k out of range, bad percentile)")
    void edgesAndValidation() {
        assertEquals(42.0, seeded().select(new double[]{42}, 0));
        assertThrows(IllegalArgumentException.class, () -> seeded().select(new double[0], 0));
        assertThrows(IllegalArgumentException.class, () -> seeded().select(null, 0));
        assertThrows(IllegalArgumentException.class, () -> seeded().select(new double[]{1, Double.NaN}, 0));
        assertThrows(IllegalArgumentException.class, () -> seeded().select(new double[]{1, 2}, 2));
        assertThrows(IllegalArgumentException.class, () -> seeded().select(new double[]{1, 2}, -1));
        assertThrows(IllegalArgumentException.class, () -> seeded().percentile(new double[]{1}, 101));
        assertThrows(IllegalArgumentException.class, () -> seeded().percentile(new double[]{1}, -0.5));
    }

    @Test
    @DisplayName("finds every rank of a small array")
    void everyRank() {
        double[] a = {9, 2, 7, 4, 5, 1, 8, 3, 6};
        for (int k = 0; k < a.length; k++) assertEquals(k + 1, seeded().select(a, k));
        assertArrayEquals(new double[]{9, 2, 7, 4, 5, 1, 8, 3, 6}, a, "select() must not modify its input");
    }

    @Test
    @DisplayName("all-equal and heavy-duplicate inputs (three-way partition)")
    void duplicates() {
        double[] same = new double[10_000];
        Arrays.fill(same, 3.5);
        RandomizedSelect s = seeded();
        assertEquals(3.5, s.select(same, 5_000));
        assertTrue(s.comparisons() <= 2 * same.length, "all-equal should finish in one pass");
        double[] few = new double[5_000];
        for (int i = 0; i < few.length; i++) few[i] = i % 3;     // only 0, 1, 2
        assertEquals(1.0, seeded().select(few, 2_500));
    }

    @Test
    @DisplayName("nearest-rank percentiles: p0 = min, p100 = max, p50 of 1..100 = 50")
    void percentiles() {
        double[] a = new double[100];
        for (int i = 0; i < 100; i++) a[i] = 100 - i;          // 100 … 1
        assertEquals(1, seeded().percentile(a, 0));
        assertEquals(50, seeded().percentile(a, 50));
        assertEquals(90, seeded().percentile(a, 90));
        assertEquals(100, seeded().percentile(a, 100));
        assertEquals(0, RandomizedSelect.rankFor(1, 99));
        assertEquals(4, RandomizedSelect.rankFor(10, 50));
        // p/100 is inexact in binary (0.55·100 = 55.000000000000007); p·n/100 is not.
        assertEquals(55, seeded().percentile(a, 55));
        assertEquals(7, seeded().percentile(a, 7));
        for (int p = 0; p <= 100; p++) assertEquals(Math.max(p, 1), seeded().percentile(a, p), "p" + p);
    }

    @Test
    @DisplayName("stress: 500 random arrays agree with sort-and-index")
    void matchesSortBaseline() {
        Random rnd = new Random(99);
        for (int t = 0; t < 500; t++) {
            int n = 1 + rnd.nextInt(2_000);
            double[] a = new double[n];
            for (int i = 0; i < n; i++) a[i] = rnd.nextInt(500) - 250 + (rnd.nextBoolean() ? 0.5 : 0);
            int k = rnd.nextInt(n);
            assertEquals(SelectBaselines.sortSelect(a, k), new RandomizedSelect(new Random(t)).select(a, k));
        }
    }

    @Test
    @DisplayName("sorted input: randomized pivot stays linear, a fixed first pivot goes quadratic")
    void adversarialSortedInput() {
        int n = 20_000;
        double[] sorted = new double[n];
        for (int i = 0; i < n; i++) sorted[i] = i;
        RandomizedSelect s = seeded();
        assertEquals(n - 1, s.select(sorted, n - 1));
        SelectBaselines.Counted naive = SelectBaselines.firstPivotSelect(sorted, n - 1);
        assertEquals(n - 1, naive.value());
        assertTrue(s.comparisons() < 10L * n, "randomized: " + s.comparisons());
        assertTrue(naive.comparisons() > (long) n * n / 4, "first pivot: " + naive.comparisons());
    }

    @Test
    @DisplayName("negative numbers, infinities and ±0 are ordered correctly")
    void specialValues() {
        double[] a = {Double.POSITIVE_INFINITY, -3, 0.0, -0.0, Double.NEGATIVE_INFINITY, 2};
        assertEquals(Double.NEGATIVE_INFINITY, seeded().select(a, 0));
        assertEquals(-3, seeded().select(a, 1));
        assertEquals(Double.POSITIVE_INFINITY, seeded().select(a, 5));
    }
}
