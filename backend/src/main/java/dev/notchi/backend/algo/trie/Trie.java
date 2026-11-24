package dev.notchi.backend.algo.trie;

import dev.notchi.backend.algo.heap.IndexedBinaryHeap;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

/**
 * Prefix tree for the island's launcher ("type to open an app, a command or a terminal tab").
 *
 * <p>Every item is indexed under each of its word starts, so "code" finds
 * "Visual Studio Code" and "vis" finds it too. Matching is case-insensitive.
 * Results are ranked by weight (how often the item was launched), then by label.
 *
 * <pre>
 * insert(label)        O(L · w)          L = label length, w = words in the label
 * search(prefix, k)    O(p + S + m log k) p = prefix length, S = nodes under the prefix,
 *                                         m = items under the prefix (top-k via a bounded heap)
 * recordUse / weight   O(1)               items are shared objects; the trie isn't touched
 * remove(id)           O(L · w)
 * space                O(total indexed characters)
 * </pre>
 *
 * <p>Children are stored in small sorted char arrays instead of a HashMap per node, which
 * keeps 100k-item tries in a few tens of MB.
 */
public final class Trie<T> {

    /** An indexed item. Weight is mutable so launches re-rank results without re-indexing. */
    public static final class Item<T> {
        private final String id;
        private final String label;
        private final T payload;
        private long weight;
        private final List<String> keys = new ArrayList<>();

        Item(String id, String label, T payload, long weight) {
            this.id = id;
            this.label = label;
            this.payload = payload;
            this.weight = weight;
        }

        public String id() { return id; }
        public String label() { return label; }
        public T payload() { return payload; }
        public long weight() { return weight; }
    }

    private static final class Node {
        char[] chars = new char[0];
        Node[] next = new Node[0];
        /** Items whose indexed key ends exactly here. Usually empty or one element. */
        List<Item<?>> terminals;

        Node child(char c) {
            int i = Arrays.binarySearch(chars, c);
            return i >= 0 ? next[i] : null;
        }

        Node childOrCreate(char c) {
            int i = Arrays.binarySearch(chars, c);
            if (i >= 0) return next[i];
            int at = -i - 1;
            char[] nc = new char[chars.length + 1];
            Node[] nn = new Node[next.length + 1];
            System.arraycopy(chars, 0, nc, 0, at);
            System.arraycopy(next, 0, nn, 0, at);
            nc[at] = c;
            nn[at] = new Node();
            System.arraycopy(chars, at, nc, at + 1, chars.length - at);
            System.arraycopy(next, at, nn, at + 1, next.length - at);
            chars = nc;
            next = nn;
            return nn[at];
        }

        void removeChild(char c) {
            int i = Arrays.binarySearch(chars, c);
            if (i < 0) return;
            char[] nc = new char[chars.length - 1];
            Node[] nn = new Node[next.length - 1];
            System.arraycopy(chars, 0, nc, 0, i);
            System.arraycopy(next, 0, nn, 0, i);
            System.arraycopy(chars, i + 1, nc, i, chars.length - i - 1);
            System.arraycopy(next, i + 1, nn, i, next.length - i - 1);
            chars = nc;
            next = nn;
        }

        boolean isEmpty() {
            return chars.length == 0 && (terminals == null || terminals.isEmpty());
        }
    }

    /** Most relevant first: higher weight, then label A→Z ignoring case, then id (so ties are stable). */
    public static final Comparator<Item<?>> RELEVANCE = Comparator
            .comparingLong((Item<?> it) -> it.weight)
            .thenComparing((Item<?> it) -> it.label, String.CASE_INSENSITIVE_ORDER.reversed())
            .thenComparing((Item<?> it) -> it.label, Comparator.reverseOrder())
            .thenComparing((Item<?> it) -> it.id, Comparator.reverseOrder());

    public static final int MAX_LABEL_LENGTH = 120;

    private final Node root = new Node();
    private final Map<String, Item<T>> byId = new HashMap<>();
    private long nodeCount = 1;

    public int size() { return byId.size(); }

    public long nodeCount() { return nodeCount; }

    public Item<T> get(String id) { return byId.get(id); }

    /** Adds an item. Ids must be unique; labels must contain at least one letter or digit. */
    public Item<T> insert(String id, String label, T payload, long weight) {
        if (id == null || id.isBlank()) throw new IllegalArgumentException("id must not be blank");
        if (label == null || label.isBlank()) throw new IllegalArgumentException("label must not be blank");
        if (label.length() > MAX_LABEL_LENGTH) {
            throw new IllegalArgumentException("label longer than " + MAX_LABEL_LENGTH + " characters");
        }
        if (weight < 0) throw new IllegalArgumentException("weight must be >= 0");
        if (byId.containsKey(id)) throw new IllegalArgumentException("duplicate id: " + id);

        List<String> keys = indexKeys(label);
        if (keys.isEmpty()) throw new IllegalArgumentException("label has no letters or digits: " + label);

        Item<T> item = new Item<>(id, label, payload, weight);
        for (String key : keys) {
            Node n = root;
            for (int i = 0; i < key.length(); i++) {
                char c = key.charAt(i);
                Node child = n.child(c);
                if (child == null) {
                    child = n.childOrCreate(c);
                    nodeCount++;
                }
                n = child;
            }
            if (n.terminals == null) n.terminals = new ArrayList<>(1);
            n.terminals.add(item);
            item.keys.add(key);
        }
        byId.put(id, item);
        return item;
    }

    /** Removes an item and prunes nodes that no longer lead anywhere. Returns false if absent. */
    public boolean remove(String id) {
        Item<T> item = byId.remove(id);
        if (item == null) return false;
        for (String key : item.keys) {
            removeKey(root, key, 0, item);
        }
        return true;
    }

    /** Returns true if this node became empty and can be unlinked from its parent. */
    private boolean removeKey(Node n, String key, int depth, Item<T> item) {
        if (depth == key.length()) {
            if (n.terminals != null) {
                n.terminals.remove(item);
                if (n.terminals.isEmpty()) n.terminals = null;
            }
            return n.isEmpty();
        }
        char c = key.charAt(depth);
        Node child = n.child(c);
        if (child == null) return false;
        if (removeKey(child, key, depth + 1, item)) {
            n.removeChild(c);   // an empty node has no children, so this unlinks exactly one node
            nodeCount--;
        }
        return n != root && n.isEmpty();
    }

    /** A launch: bumps the item's weight so it ranks higher next time. */
    public void recordUse(String id) {
        Item<T> item = byId.get(id);
        if (item == null) throw new IllegalArgumentException("unknown id: " + id);
        item.weight++;
    }

    /**
     * Up to {@code k} items with a word starting with {@code prefix}, most relevant first.
     * An empty prefix returns the k most-used items overall.
     */
    public List<Item<T>> search(String prefix, int k) {
        if (prefix == null) throw new IllegalArgumentException("prefix must not be null");
        if (k <= 0) throw new IllegalArgumentException("k must be > 0");
        String p = normalize(prefix).strip();
        Node n = root;
        for (int i = 0; i < p.length() && n != null; i++) {
            n = n.child(p.charAt(i));
        }
        if (n == null) return List.of();

        // Bounded heap of the k best so far, with the *least* relevant at the root so it can
        // be evicted in O(log k) when a better item turns up.
        IndexedBinaryHeap<String, Item<T>> best = new IndexedBinaryHeap<>(RELEVANCE.reversed());
        Set<String> seen = new HashSet<>();
        collect(n, k, best, seen);

        List<Item<T>> out = new ArrayList<>(best.size());
        while (!best.isEmpty()) out.add(best.poll().getValue());
        // Polled least-relevant first; reverse to most-relevant first.
        java.util.Collections.reverse(out);
        return out;
    }

    @SuppressWarnings("unchecked")
    private void collect(Node start, int k, IndexedBinaryHeap<String, Item<T>> best, Set<String> seen) {
        // Iterative DFS so deep tries can't overflow the call stack.
        ArrayList<Node> stack = new ArrayList<>();
        stack.add(start);
        while (!stack.isEmpty()) {
            Node n = stack.remove(stack.size() - 1);
            if (n.terminals != null) {
                for (Item<?> raw : n.terminals) {
                    Item<T> it = (Item<T>) raw;
                    if (!seen.add(it.id)) continue;     // same item reached via another word
                    if (best.size() < k) {
                        best.push(it.id, it);
                    } else if (RELEVANCE.compare(it, best.peek().getValue()) > 0) {
                        best.poll();
                        best.push(it.id, it);
                    }
                }
            }
            for (Node c : n.next) stack.add(c);
        }
    }

    // ---- key generation ---------------------------------------------------------------

    /**
     * Lower-cases and replaces anything that isn't a letter or digit with a single space.
     * Works on code points, so letters outside the BMP (e.g. 𝐀) count as letters.
     */
    static String normalize(String s) {
        String lower = s.toLowerCase(Locale.ROOT);
        StringBuilder b = new StringBuilder(lower.length());
        boolean space = false;
        for (int i = 0; i < lower.length(); ) {
            int cp = lower.codePointAt(i);
            i += Character.charCount(cp);
            if (Character.isLetterOrDigit(cp)) {
                b.appendCodePoint(cp);
                space = false;
            } else if (!space && b.length() > 0) {
                b.append(' ');
                space = true;
            }
        }
        return b.toString();
    }

    /** "Visual Studio Code" → ["visual studio code", "studio code", "code"]. */
    static List<String> indexKeys(String label) {
        String norm = normalize(label).strip();
        List<String> keys = new ArrayList<>();
        if (norm.isEmpty()) return keys;
        keys.add(norm);
        for (int i = 1; i < norm.length(); i++) {
            if (norm.charAt(i - 1) == ' ') keys.add(norm.substring(i));
        }
        return keys;
    }

    /** Counts nodes by walking the whole trie. O(nodes); tests use it to check {@link #nodeCount()}. */
    long countNodesSlow() {
        long count = 0;
        ArrayList<Node> stack = new ArrayList<>();
        stack.add(root);
        while (!stack.isEmpty()) {
            Node n = stack.remove(stack.size() - 1);
            count++;
            for (Node c : n.next) stack.add(c);
        }
        return count;
    }

    /** Linear-scan baseline used by tests and benchmarks: checks every item's word starts. */
    public static <T> List<Item<T>> linearSearch(Iterable<Item<T>> items, String prefix, int k) {
        Objects.requireNonNull(items);
        String p = normalize(prefix).strip();
        List<Item<T>> hits = new ArrayList<>();
        for (Item<T> it : items) {
            for (String key : it.keys) {
                if (key.startsWith(p)) {
                    hits.add(it);
                    break;
                }
            }
        }
        hits.sort(RELEVANCE.reversed());
        return hits.size() > k ? hits.subList(0, k) : hits;
    }

    /** All items (for the baseline and for listing). */
    public Iterable<Item<T>> items() { return byId.values(); }
}
