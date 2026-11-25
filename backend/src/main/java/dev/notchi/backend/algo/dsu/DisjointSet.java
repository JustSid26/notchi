package dev.notchi.backend.algo.dsu;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Disjoint-set union (union–find) with union by rank and path compression.
 *
 * <p>Notchi's Workspaces put two apps in the same set when you keep using them together;
 * each set with two or more apps becomes a workspace you can open in one click. Because
 * "used together" is transitive (Figma–Slack and Slack–Chrome make one design workspace),
 * this is exactly connected components, built one edge at a time.
 *
 * <pre>
 * find / union / connected   O(α(n)) amortised   (α = inverse Ackermann, ≤ 4 in practice)
 * groups()                   O(n α(n))
 * space                      O(n)
 * baseline                   rebuild components with BFS after every new edge: O(n + e) each
 * </pre>
 */
public final class DisjointSet {

    private int[] parent;
    private int[] rank;
    private int[] size;
    private int count;
    private int components;

    public DisjointSet(int n) {
        if (n < 0) throw new IllegalArgumentException("n must be >= 0");
        parent = new int[Math.max(4, n)];
        rank = new int[parent.length];
        size = new int[parent.length];
        for (int i = 0; i < n; i++) add();
    }

    /** Adds a new singleton element and returns its index. */
    public int add() {
        if (count == parent.length) {
            int cap = parent.length * 2;
            parent = Arrays.copyOf(parent, cap);
            rank = Arrays.copyOf(rank, cap);
            size = Arrays.copyOf(size, cap);
        }
        parent[count] = count;
        size[count] = 1;
        components++;
        return count++;
    }

    public int elements() { return count; }

    public int components() { return components; }

    /** Representative of x's set. Iterative two-pass path compression. */
    public int find(int x) {
        check(x);
        int root = x;
        while (parent[root] != root) root = parent[root];
        while (parent[x] != root) {
            int next = parent[x];
            parent[x] = root;
            x = next;
        }
        return root;
    }

    /** Merges the sets of a and b. Returns false if they were already together. */
    public boolean union(int a, int b) {
        int ra = find(a), rb = find(b);
        if (ra == rb) return false;
        if (rank[ra] < rank[rb]) { int t = ra; ra = rb; rb = t; }
        parent[rb] = ra;                         // attach the shallower tree under the deeper one
        size[ra] += size[rb];
        if (rank[ra] == rank[rb]) rank[ra]++;
        components--;
        return true;
    }

    public boolean connected(int a, int b) { return find(a) == find(b); }

    /** Size of x's set. */
    public int sizeOf(int x) { return size[find(x)]; }

    /** All sets as lists of members, keyed by representative, in order of first member. */
    public Map<Integer, List<Integer>> groups() {
        Map<Integer, List<Integer>> g = new LinkedHashMap<>();
        for (int i = 0; i < count; i++) g.computeIfAbsent(find(i), r -> new ArrayList<>()).add(i);
        return g;
    }

    private void check(int x) {
        if (x < 0 || x >= count) throw new IndexOutOfBoundsException("element " + x + " outside 0.." + (count - 1));
    }
}
