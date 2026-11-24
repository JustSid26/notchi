package dev.notchi.backend.algo.bloom;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class BloomFilterTest {

    @Test
    @DisplayName("edge: an empty filter contains nothing")
    void emptyFilter() {
        BloomFilter f = BloomFilter.forExpected(1000, 0.01);
        assertFalse(f.mightContain("anything"));
        assertFalse(f.mightContain(""));
        assertEquals(0, f.insertedCount());
        assertEquals(0.0, f.fillRatio());
        assertEquals(0.0, f.expectedFalsePositiveRate());
    }

    @Test
    @DisplayName("no false negatives: every inserted key is reported as possibly present")
    void noFalseNegatives() {
        BloomFilter f = BloomFilter.forExpected(50_000, 0.01);
        for (int i = 0; i < 50_000; i++) f.add("event-" + i);
        for (int i = 0; i < 50_000; i++) assertTrue(f.mightContain("event-" + i), "lost event-" + i);
    }

    @Test
    @DisplayName("sizing follows m = −n·ln p / (ln 2)², k = (m/n)·ln 2")
    void optimalSizing() {
        assertEquals(95851, BloomFilter.optimalBits(10_000, 0.01));     // ≈ 9.585 bits per key
        assertEquals(7, BloomFilter.optimalHashes(10_000, 95851));
        BloomFilter f = BloomFilter.forExpected(10_000, 0.01);
        assertEquals(95851, f.bitCount());
        assertEquals(7, f.hashCount());
        assertEquals((95851 + 63) / 64 * 8, f.sizeInBytes());
    }

    @Test
    @DisplayName("measured false-positive rate stays close to the target (1%)")
    void falsePositiveRateNearTarget() {
        int n = 20_000;
        BloomFilter f = BloomFilter.forExpected(n, 0.01);
        for (int i = 0; i < n; i++) f.add("in-" + i);
        int fp = 0, trials = 200_000;
        for (int i = 0; i < trials; i++) if (f.mightContain("out-" + i)) fp++;
        double rate = (double) fp / trials;
        assertTrue(rate > 0.005 && rate < 0.015, "observed " + rate);
        assertEquals(0.01, f.expectedFalsePositiveRate(), 0.001);
        assertEquals(0.5, f.fillRatio(), 0.02);   // an optimally sized filter ends half full
    }

    @Test
    @DisplayName("add() returns true for a new key and false for an exact repeat")
    void addReportsNewness() {
        BloomFilter f = BloomFilter.forExpected(100, 0.01);
        assertTrue(f.add("deploy@1"));
        assertFalse(f.add("deploy@1"));
        assertEquals(2, f.insertedCount());
    }

    @Test
    @DisplayName("boundary: overfilling raises the false-positive rate as theory predicts")
    void overfilledFilter() {
        BloomFilter f = BloomFilter.forExpected(1_000, 0.01);
        for (int i = 0; i < 10_000; i++) f.add("k" + i);      // 10× the planned load
        int fp = 0;
        for (int i = 0; i < 20_000; i++) if (f.mightContain("other" + i)) fp++;
        double rate = fp / 20_000.0;
        assertTrue(rate > 0.5, "an overfilled filter should mostly say 'maybe', got " + rate);
        assertEquals(f.expectedFalsePositiveRate(), rate, 0.05);
    }

    @Test
    @DisplayName("invalid parameters are rejected")
    void invalidParameters() {
        assertThrows(IllegalArgumentException.class, () -> BloomFilter.forExpected(0, 0.01));
        assertThrows(IllegalArgumentException.class, () -> BloomFilter.forExpected(100, 0));
        assertThrows(IllegalArgumentException.class, () -> BloomFilter.forExpected(100, 1));
        assertThrows(IllegalArgumentException.class, () -> BloomFilter.forExpected(100, Double.NaN));
        assertThrows(IllegalArgumentException.class, () -> new BloomFilter(0, 3));
        assertThrows(IllegalArgumentException.class, () -> new BloomFilter(64, 0));
        assertThrows(IllegalArgumentException.class, () -> BloomFilter.forExpected(2_000_000_000L, 1e-9));
        BloomFilter f = BloomFilter.forExpected(10, 0.1);
        assertThrows(IllegalArgumentException.class, () -> f.add(null));
    }
}
