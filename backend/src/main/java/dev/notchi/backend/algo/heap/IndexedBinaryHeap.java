package dev.notchi.backend.algo.heap;

import java.util.AbstractMap;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.Objects;

/**
 * An array-backed binary heap where every element has a unique key, so an element can be
 * found, re-prioritised or removed in O(log n) (an "indexed" or "addressable" priority queue).
 *
 * <p>Notchi uses it for the LIVE queue: activities change state all the time (running →
 * needs approval → done), and the island must always show the most urgent ones first.
 *
 * <p>Ordering: {@code priority.compare(a, b) > 0} means {@code a} is more urgent than
 * {@code b} and belongs closer to the root. The root is always the most urgent element.
 *
 * <p>Invariant (heap order): for every index i &gt; 0,
 * {@code priority.compare(value[parent(i)], value[i]) >= 0}.
 * Invariant (index map): {@code position.get(keys[i]) == i} for every i.
 *
 * <pre>
 * operation        time          notes
 * push / update    O(log n)      sift up or down along one root-to-leaf path
 * poll / remove    O(log n)      move the last element into the hole, then sift
 * peek / get       O(1)
 * topK(k)          O(k log k)    best-first walk of the heap tree; the heap is not modified
 * space            O(n)
 * </pre>
 *
 * <p>Not thread-safe; callers synchronise (see {@code LiveQueue}).
 *
 * @param <K> key type (must have proper equals/hashCode)
 * @param <V> value type, ordered by the comparator
 */
public final class IndexedBinaryHeap<K, V> {

    private final Comparator<? super V> priority;
    private final ArrayList<K> keys = new ArrayList<>();
    private final ArrayList<V> values = new ArrayList<>();
    /** key → index in the arrays; Java's HashMap is only used as a lookup table here. */
    private final HashMap<K, Integer> position = new HashMap<>();

    public IndexedBinaryHeap(Comparator<? super V> priority) {
        this.priority = Objects.requireNonNull(priority, "priority");
    }

    public int size() { return keys.size(); }

    public boolean isEmpty() { return keys.isEmpty(); }

    public boolean contains(K key) { return position.containsKey(key); }

    /** The value stored for {@code key}, or {@code null}. O(1). */
    public V get(K key) {
        Integer i = position.get(key);
        return i == null ? null : values.get(i);
    }

    /** Inserts a new key. Throws if the key is already present (use {@link #upsert}). */
    public void push(K key, V value) {
        Objects.requireNonNull(key, "key");
        Objects.requireNonNull(value, "value");
        if (position.containsKey(key)) {
            throw new IllegalArgumentException("Key already in heap: " + key);
        }
        keys.add(key);
        values.add(value);
        position.put(key, keys.size() - 1);
        siftUp(keys.size() - 1);
    }

    /** Replaces the value of an existing key and restores heap order. */
    public void update(K key, V value) {
        Objects.requireNonNull(value, "value");
        Integer i = position.get(key);
        if (i == null) {
            throw new NoSuchElementException("Key not in heap: " + key);
        }
        V old = values.set(i, value);
        int c = priority.compare(value, old);
        if (c > 0) {
            siftUp(i);          // became more urgent: can only move towards the root
        } else if (c < 0) {
            siftDown(i);        // became less urgent: can only move towards the leaves
        }
    }

    /** Inserts or updates. Returns true if the key was new. */
    public boolean upsert(K key, V value) {
        if (position.containsKey(key)) {
            update(key, value);
            return false;
        }
        push(key, value);
        return true;
    }

    /** The most urgent entry without removing it. */
    public Map.Entry<K, V> peek() {
        if (isEmpty()) {
            throw new NoSuchElementException("Heap is empty");
        }
        return entry(0);
    }

    /** Removes and returns the most urgent entry. */
    public Map.Entry<K, V> poll() {
        if (isEmpty()) {
            throw new NoSuchElementException("Heap is empty");
        }
        Map.Entry<K, V> top = entry(0);
        removeAt(0);
        return top;
    }

    /** Removes {@code key}; returns its value, or {@code null} if it wasn't present. */
    public V remove(K key) {
        Integer i = position.get(key);
        if (i == null) {
            return null;
        }
        V v = values.get(i);
        removeAt(i);
        return v;
    }

    /**
     * The {@code k} most urgent entries, most urgent first, without modifying the heap.
     *
     * <p>Best-first search: the root is the best element; the next best is always a child of
     * an element already taken. A small "frontier" heap of candidate indices (itself an
     * IndexedBinaryHeap) yields them in order: each step pops one index and pushes its
     * two children, so the frontier never exceeds k + 1 entries. O(k log k).
     */
    public List<Map.Entry<K, V>> topK(int k) {
        if (k < 0) {
            throw new IllegalArgumentException("k must be >= 0");
        }
        int n = Math.min(k, size());
        List<Map.Entry<K, V>> out = new ArrayList<>(n);
        if (n == 0) {
            return out;
        }
        IndexedBinaryHeap<Integer, Integer> frontier =
                new IndexedBinaryHeap<>((a, b) -> priority.compare(values.get(a), values.get(b)));
        frontier.push(0, 0);
        while (out.size() < n) {
            int i = frontier.poll().getKey();
            out.add(entry(i));
            int l = 2 * i + 1, r = l + 1;
            if (l < size()) frontier.push(l, l);
            if (r < size()) frontier.push(r, r);
        }
        return out;
    }

    /** Checks both invariants. Used by tests; O(n). */
    boolean isValid() {
        for (int i = 0; i < size(); i++) {
            if (!Objects.equals(position.get(keys.get(i)), i)) return false;
            if (i > 0 && priority.compare(values.get(parent(i)), values.get(i)) < 0) return false;
        }
        return position.size() == size();
    }

    // ---- internals -------------------------------------------------------------------

    private static int parent(int i) { return (i - 1) / 2; }

    private Map.Entry<K, V> entry(int i) {
        return new AbstractMap.SimpleImmutableEntry<>(keys.get(i), values.get(i));
    }

    private void removeAt(int i) {
        int last = size() - 1;
        swap(i, last);
        position.remove(keys.get(last));
        keys.remove(last);
        values.remove(last);
        if (i < size()) {
            // The element moved into the hole may be more or less urgent than its new
            // neighbours, so try both directions (only one of them will move it).
            siftUp(i);
            siftDown(i);
        }
    }

    private void siftUp(int i) {
        while (i > 0) {
            int p = parent(i);
            if (priority.compare(values.get(i), values.get(p)) <= 0) {
                break;
            }
            swap(i, p);
            i = p;
        }
    }

    private void siftDown(int i) {
        int n = size();
        while (true) {
            int l = 2 * i + 1, r = l + 1, best = i;
            if (l < n && priority.compare(values.get(l), values.get(best)) > 0) best = l;
            if (r < n && priority.compare(values.get(r), values.get(best)) > 0) best = r;
            if (best == i) {
                return;
            }
            swap(i, best);
            i = best;
        }
    }

    private void swap(int a, int b) {
        if (a == b) return;
        K ka = keys.get(a), kb = keys.get(b);
        keys.set(a, kb);
        keys.set(b, ka);
        V va = values.get(a);
        values.set(a, values.get(b));
        values.set(b, va);
        position.put(kb, a);
        position.put(ka, b);
    }
}
