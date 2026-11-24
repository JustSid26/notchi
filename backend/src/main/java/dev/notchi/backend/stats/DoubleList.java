package dev.notchi.backend.stats;

import java.util.Arrays;

/** A growable array of primitive doubles (no boxing), doubling its capacity when full. */
final class DoubleList {
    private double[] data = new double[16];
    private int size;

    void add(double v) {
        if (size == data.length) data = Arrays.copyOf(data, size * 2);   // amortized O(1)
        data[size++] = v;
    }

    int size() { return size; }

    /** A copy of the values (select works in place, so callers get their own array). */
    double[] toArray() { return Arrays.copyOf(data, size); }
}
