package dev.notchi.backend.algo.tree;

/**
 * A segment tree over n non-negative counters, answering range sums and range maxima with
 * point updates. Notchi's screen time keeps one per app per day with a leaf per minute
 * (seconds active in that minute), so "time in Figma from 2 pm to 5 pm", the hourly bars and
 * the busiest hour are all O(log n) queries.
 *
 * <p>Layout: an implicit complete binary tree in arrays of size 2·size (size = n rounded up
 * to a power of two). Leaves live at [size, 2·size); node i covers the union of its children
 * 2i and 2i+1. Iterative bottom-up update and query, no recursion.
 *
 * <pre>
 * add / set        O(log n)   walk from the leaf to the root, recomputing sum and max
 * sum / max        O(log n)   at most 2 nodes per level cover any range
 * argMax           O(log n)   descend towards the larger child inside the range
 * space            O(n)
 * baselines        plain array: O(1) update, O(r − l) query
 *                  prefix sums: O(1) query, O(n) update
 * </pre>
 */
public final class SegmentTree {

    private final int n;
    private final int size;
    private final long[] sum;
    private final long[] max;

    public SegmentTree(int n) {
        if (n <= 0) throw new IllegalArgumentException("n must be > 0");
        if (n > (1 << 26)) throw new IllegalArgumentException("n too large");
        this.n = n;
        int s = 1;
        while (s < n) s <<= 1;
        this.size = s;
        this.sum = new long[2 * s];
        this.max = new long[2 * s];
    }

    public int size() { return n; }

    /** Adds {@code delta} to position i (the result must stay ≥ 0). */
    public void add(int i, long delta) {
        check(i);
        set(i, sum[size + i] + delta);
    }

    /** Sets position i to {@code value} (≥ 0). */
    public void set(int i, long value) {
        check(i);
        if (value < 0) throw new IllegalArgumentException("values must be >= 0");
        int p = size + i;
        sum[p] = value;
        max[p] = value;
        for (p >>= 1; p >= 1; p >>= 1) {
            sum[p] = sum[2 * p] + sum[2 * p + 1];
            max[p] = Math.max(max[2 * p], max[2 * p + 1]);
        }
    }

    public long get(int i) {
        check(i);
        return sum[size + i];
    }

    /** Sum of positions [l, r). */
    public long sum(int l, int r) {
        checkRange(l, r);
        long s = 0;
        for (int a = l + size, b = r + size; a < b; a >>= 1, b >>= 1) {
            if ((a & 1) == 1) s += sum[a++];
            if ((b & 1) == 1) s += sum[--b];
        }
        return s;
    }

    /** Largest value in positions [l, r); 0 for an empty range. */
    public long max(int l, int r) {
        checkRange(l, r);
        long m = 0;
        for (int a = l + size, b = r + size; a < b; a >>= 1, b >>= 1) {
            if ((a & 1) == 1) m = Math.max(m, max[a++]);
            if ((b & 1) == 1) m = Math.max(m, max[--b]);
        }
        return m;
    }

    /** First position in [l, r) holding the range maximum, or -1 for an empty range. */
    public int argMax(int l, int r) {
        checkRange(l, r);
        if (l == r) return -1;
        long target = max(l, r);
        return firstAtLeast(1, 0, size, l, r, target);
    }

    /** Leftmost leaf in [l, r) under node (covering [nl, nr)) with value ≥ target. */
    private int firstAtLeast(int node, int nl, int nr, int l, int r, long target) {
        if (nr <= l || r <= nl || max[node] < target) return -1;
        if (nr - nl == 1) return nl;
        int mid = (nl + nr) >>> 1;
        int left = firstAtLeast(2 * node, nl, mid, l, r, target);
        return left != -1 ? left : firstAtLeast(2 * node + 1, mid, nr, l, r, target);
    }

    private void check(int i) {
        if (i < 0 || i >= n) throw new IndexOutOfBoundsException("index " + i + " outside 0.." + (n - 1));
    }

    private void checkRange(int l, int r) {
        if (l < 0 || r > n || l > r) throw new IndexOutOfBoundsException("range [" + l + ", " + r + ") outside [0, " + n + ")");
    }
}
