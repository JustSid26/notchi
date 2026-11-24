package dev.notchi.backend.algo.select;

import java.util.Random;
import java.util.random.RandomGenerator;

/**
 * Randomized Quickselect (a Las Vegas algorithm): finds the k-th smallest value in expected
 * linear time without sorting.
 *
 * <p>Notchi uses it for Claude's ETA: from the durations of past Claude runs it picks the
 * median (p50) and p90, so a terminal tab can say "usually done in ~2:14".
 *
 * <p>Each round picks a uniformly random pivot and splits the range three ways
 * (&lt; pivot, = pivot, &gt; pivot), then continues only in the part that holds rank k.
 * The three-way split keeps it linear even when many durations are equal.
 *
 * <pre>
 * expected time   O(n)   (a two-way partition needs ≈ 3.4n comparisons for the median; this
 *                        three-way one counts up to two per element, ≈ 5n measured; always exact)
 * worst case      O(n²)  only with vanishing probability; no input can force it,
 *                        unlike a fixed "first element" pivot on sorted data
 * extra space     O(1)   iterative, partitions in place
 * </pre>
 *
 * <p>Not thread-safe (it counts comparisons); create one per use.
 */
public final class RandomizedSelect {

    private final RandomGenerator random;
    private long comparisons;

    public RandomizedSelect() { this(new Random()); }

    /** Pass a seeded generator for reproducible runs. */
    public RandomizedSelect(RandomGenerator random) { this.random = random; }

    /** Element comparisons made since construction (for the complexity experiments). */
    public long comparisons() { return comparisons; }

    /**
     * The k-th smallest value (k = 0 is the minimum). Reorders {@code a} in place.
     *
     * @throws IllegalArgumentException if {@code a} is empty, k is out of range, or a is NaN-tainted
     */
    public double selectInPlace(double[] a, int k) {
        validate(a);
        return quickselect(a, k);
    }

    private double quickselect(double[] a, int k) {
        if (k < 0 || k >= a.length) {
            throw new IllegalArgumentException("k = " + k + " is outside 0.." + (a.length - 1));
        }
        int lo = 0, hi = a.length - 1;
        while (true) {
            if (lo == hi) return a[lo];
            double pivot = a[lo + random.nextInt(hi - lo + 1)];
            // Dutch-flag partition of a[lo..hi]:
            //   a[lo..lt-1] < pivot,  a[lt..i-1] == pivot,  a[gt+1..hi] > pivot
            int lt = lo, i = lo, gt = hi;
            while (i <= gt) {
                double v = a[i];
                comparisons++;
                if (v < pivot) {
                    swap(a, lt++, i++);
                } else {
                    comparisons++;
                    if (v > pivot) swap(a, i, gt--);
                    else i++;
                }
            }
            if (k < lt) hi = lt - 1;            // answer is among the smaller values
            else if (k > gt) lo = gt + 1;       // … or among the larger ones
            else return pivot;                  // k falls in the block equal to the pivot
        }
    }

    /** Like {@link #selectInPlace} but leaves the input untouched (works on a copy). */
    public double select(double[] a, int k) {
        validate(a);
        return quickselect(a.clone(), k);
    }

    /**
     * Nearest-rank percentile: the smallest value with at least p% of the data at or below it.
     * p = 0 gives the minimum, p = 100 the maximum.
     */
    public double percentile(double[] a, double p) {
        validate(a);
        return quickselect(a.clone(), rankFor(a.length, p));
    }

    /** 0-based rank used for percentile p of n values. */
    public static int rankFor(int n, double p) {
        if (!(p >= 0 && p <= 100)) throw new IllegalArgumentException("percentile must be between 0 and 100");
        if (n <= 0) throw new IllegalArgumentException("no data");
        int rank = (int) Math.ceil(p * n / 100.0);   // 1-based; p·n first keeps 55% of 100 exactly 55
        return Math.max(0, Math.min(n - 1, rank - 1));
    }

    private static void validate(double[] a) {
        if (a == null || a.length == 0) throw new IllegalArgumentException("no data");
        for (double v : a) {
            if (Double.isNaN(v)) throw new IllegalArgumentException("data contains NaN");
        }
    }

    private static void swap(double[] a, int i, int j) {
        double t = a[i];
        a[i] = a[j];
        a[j] = t;
    }
}
