package dev.notchi.backend.algo.select;

import java.util.Arrays;

/**
 * Baselines that {@link RandomizedSelect} is compared against in tests and benchmarks.
 * They are not used by the running backend.
 */
public final class SelectBaselines {

    private SelectBaselines() {}

    /** Sort a copy, then index: O(n log n). Simple and always correct. */
    public static double sortSelect(double[] a, int k) {
        double[] c = a.clone();
        Arrays.sort(c);
        return c[k];
    }

    /** Result of {@link #firstPivotSelect}: the value and how many comparisons it took. */
    public record Counted(double value, long comparisons) {}

    /**
     * Quickselect with a fixed pivot (the first element) and a two-way Lomuto partition.
     * Fine on shuffled data, but O(n²) on already-sorted input — exactly the input that
     * randomization protects against. Iterative, so it can't overflow the stack.
     */
    public static Counted firstPivotSelect(double[] input, int k) {
        double[] a = input.clone();
        long comparisons = 0;
        int lo = 0, hi = a.length - 1;
        while (lo < hi) {
            double pivot = a[lo];
            int store = lo;
            for (int i = lo + 1; i <= hi; i++) {
                comparisons++;
                if (a[i] < pivot) {
                    store++;
                    double t = a[store]; a[store] = a[i]; a[i] = t;
                }
            }
            double t = a[lo]; a[lo] = a[store]; a[store] = t;
            if (k == store) return new Counted(a[store], comparisons);
            if (k < store) hi = store - 1; else lo = store + 1;
        }
        return new Counted(a[lo], comparisons);
    }
}
