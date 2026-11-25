package dev.notchi.backend.algo.dsu;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

class DisjointSetTest {

    @Test
    @DisplayName("edge: an empty structure, and singletons are their own sets")
    void edges() {
        DisjointSet d = new DisjointSet(0);
        assertEquals(0, d.components());
        assertTrue(d.groups().isEmpty());
        assertThrows(IndexOutOfBoundsException.class, () -> d.find(0));
        int a = d.add();
        assertEquals(a, d.find(a));
        assertEquals(1, d.sizeOf(a));
        assertThrows(IllegalArgumentException.class, () -> new DisjointSet(-1));
    }

    @Test
    @DisplayName("union merges transitively (Figma–Slack + Slack–Chrome = one workspace)")
    void transitive() {
        DisjointSet d = new DisjointSet(4);   // 0 Figma, 1 Slack, 2 Chrome, 3 Xcode
        assertTrue(d.union(0, 1));
        assertTrue(d.union(1, 2));
        assertTrue(d.connected(0, 2));
        assertFalse(d.connected(0, 3));
        assertEquals(3, d.sizeOf(2));
        assertEquals(2, d.components());
    }

    @Test
    @DisplayName("a repeated union is a no-op and returns false")
    void repeatedUnion() {
        DisjointSet d = new DisjointSet(3);
        assertTrue(d.union(0, 1));
        assertFalse(d.union(1, 0));
        assertFalse(d.union(0, 0));
        assertEquals(2, d.components());
    }

    @Test
    @DisplayName("groups() lists every set's members")
    void groups() {
        DisjointSet d = new DisjointSet(6);
        d.union(0, 3);
        d.union(4, 5);
        d.union(3, 5);
        List<List<Integer>> g = new ArrayList<>(d.groups().values());
        assertEquals(List.of(List.of(0, 3, 4, 5), List.of(1), List.of(2)), g);
    }

    @Test
    @DisplayName("boundary: a 100,000-element chain stays shallow (no stack overflow, fast finds)")
    void longChain() {
        int n = 100_000;
        DisjointSet d = new DisjointSet(n);
        for (int i = 1; i < n; i++) d.union(i - 1, i);
        assertEquals(1, d.components());
        assertEquals(n, d.sizeOf(0));
        assertTrue(d.connected(0, n - 1));
    }

    @Test
    @DisplayName("stress: random unions agree with BFS over the same edges")
    void matchesBfsBaseline() {
        Random r = new Random(9);
        int n = 300;
        DisjointSet d = new DisjointSet(n);
        List<List<Integer>> adj = new ArrayList<>();
        for (int i = 0; i < n; i++) adj.add(new ArrayList<>());
        for (int e = 0; e < 250; e++) {
            int a = r.nextInt(n), b = r.nextInt(n);
            d.union(a, b);
            adj.get(a).add(b);
            adj.get(b).add(a);
            if (e % 25 == 0) {
                int[] comp = bfsComponents(adj);
                for (int q = 0; q < 200; q++) {
                    int x = r.nextInt(n), y = r.nextInt(n);
                    assertEquals(comp[x] == comp[y], d.connected(x, y));
                }
            }
        }
    }

    static int[] bfsComponents(List<List<Integer>> adj) {
        int[] comp = new int[adj.size()];
        java.util.Arrays.fill(comp, -1);
        int c = 0;
        for (int s = 0; s < adj.size(); s++) {
            if (comp[s] != -1) continue;
            ArrayDeque<Integer> q = new ArrayDeque<>(List.of(s));
            comp[s] = c;
            while (!q.isEmpty()) {
                int u = q.poll();
                for (int v : adj.get(u)) if (comp[v] == -1) { comp[v] = c; q.add(v); }
            }
            c++;
        }
        return comp;
    }
}
