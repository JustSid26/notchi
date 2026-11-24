package dev.notchi.backend.algo.bloom;

import java.nio.charset.StandardCharsets;

/**
 * A Bloom filter: a bit array plus k hash functions that answers "have I seen this key?" with
 * either <b>definitely not</b> or <b>possibly yes</b>. It never gives a false negative; false
 * positives happen with a probability we choose up front.
 *
 * <p>Notchi puts one in front of its event log so that most incoming events (which are new)
 * skip the exact lookup entirely. A "possibly yes" is always confirmed against the exact log
 * before an event is dropped, so a false positive can never lose an event.
 *
 * <p>Sizing for n expected keys and target false-positive rate p:
 * <pre>
 *   m = ceil(-n · ln p / (ln 2)²)   bits
 *   k = round((m / n) · ln 2)        hash functions
 *   expected false-positive rate after n inserts ≈ (1 − e^(−k·n/m))^k
 * </pre>
 *
 * <p>Hashing: two independent 64-bit hashes of the key's UTF-8 bytes (FNV-1a and a
 * MurmurHash3-style mix), combined as h1 + i·h2 for i = 0..k−1 (Kirsch–Mitzenmacher
 * double hashing), which matches k independent hashes asymptotically.
 *
 * <pre>
 * add / mightContain   O(k + |key|)
 * space                m bits (≈ 1.2 bytes per key at p = 1%)
 * </pre>
 */
public final class BloomFilter {

    /** Largest bit array we allow (2^31 − 1 bits ≈ 256 MB): indices are ints. */
    public static final long MAX_BITS = Integer.MAX_VALUE;

    private final long[] words;
    private final int m;
    private final int k;
    private long inserted;
    private long bitsSet;

    /** A filter with exactly {@code bits} bits and {@code hashes} hash functions. */
    public BloomFilter(int bits, int hashes) {
        if (bits <= 0) throw new IllegalArgumentException("bits must be > 0");
        if (hashes <= 0 || hashes > 64) throw new IllegalArgumentException("hashes must be in 1..64");
        this.m = bits;
        this.k = hashes;
        this.words = new long[(int) ((bits + 63L) / 64)];
    }

    /** A filter sized for {@code expectedKeys} keys at false-positive rate {@code fpp}. */
    public static BloomFilter forExpected(long expectedKeys, double fpp) {
        long bits = optimalBits(expectedKeys, fpp);
        return new BloomFilter((int) bits, optimalHashes(expectedKeys, bits));
    }

    public static long optimalBits(long n, double p) {
        if (n <= 0) throw new IllegalArgumentException("expected keys must be > 0");
        if (!(p > 0 && p < 1)) throw new IllegalArgumentException("false-positive rate must be between 0 and 1");
        double bits = Math.ceil(-n * Math.log(p) / (Math.log(2) * Math.log(2)));
        if (bits > MAX_BITS) throw new IllegalArgumentException("filter would need more than " + MAX_BITS + " bits");
        return Math.max(64, (long) bits);
    }

    public static int optimalHashes(long n, long m) {
        if (n <= 0 || m <= 0) throw new IllegalArgumentException("n and m must be > 0");
        return (int) Math.max(1, Math.min(64, Math.round((double) m / n * Math.log(2))));
    }

    /**
     * Adds a key. Returns true if at least one bit changed, which proves the key was
     * definitely not present before.
     */
    public boolean add(String key) {
        byte[] b = bytes(key);
        long h1 = fnv1a64(b), h2 = murmurMix64(b);
        boolean changed = false;
        for (int i = 0; i < k; i++) {
            int bit = index(h1, h2, i);
            long mask = 1L << (bit & 63);
            int w = bit >>> 6;
            if ((words[w] & mask) == 0) {
                words[w] |= mask;
                bitsSet++;
                changed = true;
            }
        }
        inserted++;
        return changed;
    }

    /** False means definitely never added. True means possibly added. */
    public boolean mightContain(String key) {
        byte[] b = bytes(key);
        long h1 = fnv1a64(b), h2 = murmurMix64(b);
        for (int i = 0; i < k; i++) {
            int bit = index(h1, h2, i);
            if ((words[bit >>> 6] & (1L << (bit & 63))) == 0) return false;
        }
        return true;
    }

    /** Theoretical false-positive rate for the number of keys inserted so far. */
    public double expectedFalsePositiveRate() {
        return Math.pow(1 - Math.exp(-(double) k * inserted / m), k);
    }

    /** Fraction of bits set; the false-positive rate is roughly fillRatio^k. */
    public double fillRatio() { return (double) bitsSet / m; }

    public int bitCount() { return m; }
    public int hashCount() { return k; }
    public long insertedCount() { return inserted; }
    public long bitsSet() { return bitsSet; }
    public long sizeInBytes() { return words.length * 8L; }

    // ---- hashing ----------------------------------------------------------------------

    private int index(long h1, long h2, int i) {
        return (int) Math.floorMod(h1 + i * h2, (long) m);
    }

    private static byte[] bytes(String key) {
        if (key == null) throw new IllegalArgumentException("key must not be null");
        return key.getBytes(StandardCharsets.UTF_8);
    }

    static long fnv1a64(byte[] data) {
        long h = 0xcbf29ce484222325L;
        for (byte x : data) {
            h ^= (x & 0xff);
            h *= 0x100000001b3L;
        }
        return h;
    }

    /** MurmurHash3-style: mixes 8 bytes at a time, then the fmix64 finaliser. */
    static long murmurMix64(byte[] data) {
        long h = 0x9E3779B97F4A7C15L ^ data.length;
        int i = 0;
        for (; i + 8 <= data.length; i += 8) {
            long kk = 0;
            for (int j = 7; j >= 0; j--) kk = (kk << 8) | (data[i + j] & 0xff);
            kk *= 0x87c37b91114253d5L;
            kk = Long.rotateLeft(kk, 31);
            kk *= 0x4cf5ad432745937fL;
            h ^= kk;
            h = Long.rotateLeft(h, 27) * 5 + 0x52dce729;
        }
        long tail = 0;
        for (int j = data.length - 1; j >= i; j--) tail = (tail << 8) | (data[j] & 0xff);
        h ^= tail * 0x87c37b91114253d5L;
        // fmix64
        h ^= h >>> 33;
        h *= 0xff51afd7ed558ccdL;
        h ^= h >>> 33;
        h *= 0xc4ceb9fe1a85ec53L;
        h ^= h >>> 33;
        // An odd step visits every residue when m is a power of two, and avoids h2 = 0.
        return h | 1L;
    }
}
