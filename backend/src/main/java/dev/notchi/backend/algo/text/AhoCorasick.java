package dev.notchi.backend.algo.text;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Aho–Corasick multi-pattern matching: a trie of all patterns plus KMP-style failure links,
 * so one left-to-right pass over the text finds every occurrence of every pattern.
 *
 * <p>Notchi's note sorter uses it to spot all of its cue words ("password", "tomorrow",
 * "https://", "buy"…, a few hundred across categories) in a note at once.
 *
 * <p>The failure link of a node is the longest proper suffix of its string that is also a
 * path in the trie (exactly KMP's prefix function, generalised from one pattern to many).
 * The output link jumps to the nearest node on the failure chain where a pattern ends, so
 * reporting matches never walks through nodes that end nothing.
 *
 * <pre>
 * build        O(L)           L = total pattern length (one BFS; failure links amortised like KMP)
 * findAll      O(n + z)       n = text length, z = number of matches
 * space        O(L)
 * baseline     KMP once per pattern: O(k · n) for k patterns
 * </pre>
 *
 * Matching is case-insensitive (patterns and text are lower-cased char by char).
 *
 * @param <T> what each pattern stands for (e.g. a category and a weight)
 */
public final class AhoCorasick<T> {

    /** One occurrence: text[start, end) matches {@code pattern}. */
    public record Match<T>(int start, int end, String pattern, T payload) {}

    private final List<Map<Character, Integer>> next = new ArrayList<>();
    private final List<List<Integer>> out = new ArrayList<>();   // pattern indices ending at node
    private int[] fail;
    private int[] outLink;                                       // nearest node on the fail chain with outputs, or -1
    private final List<String> patterns = new ArrayList<>();
    private final List<T> payloads = new ArrayList<>();
    private boolean built;

    public AhoCorasick() {
        newNode();
    }

    /** Adds a pattern (before {@link #build()}). Empty patterns are rejected. */
    public AhoCorasick<T> add(String pattern, T payload) {
        if (built) throw new IllegalStateException("already built");
        if (pattern == null || pattern.isEmpty()) throw new IllegalArgumentException("pattern must not be empty");
        int node = 0;
        for (int i = 0; i < pattern.length(); i++) {
            char c = Character.toLowerCase(pattern.charAt(i));
            Integer child = next.get(node).get(c);
            if (child == null) {
                child = newNode();
                next.get(node).put(c, child);
            }
            node = child;
        }
        out.get(node).add(patterns.size());
        patterns.add(pattern.toLowerCase());
        payloads.add(payload);
        return this;
    }

    /** Computes failure and output links breadth-first. Call once, after adding patterns. */
    public AhoCorasick<T> build() {
        if (built) return this;
        int n = next.size();
        fail = new int[n];
        outLink = new int[n];
        outLink[0] = -1;
        ArrayDeque<Integer> queue = new ArrayDeque<>();
        for (int child : next.get(0).values()) {
            fail[child] = 0;
            outLink[child] = -1;
            queue.add(child);
        }
        while (!queue.isEmpty()) {
            int u = queue.poll();
            for (Map.Entry<Character, Integer> e : next.get(u).entrySet()) {
                char c = e.getKey();
                int v = e.getValue();
                // Longest proper suffix of (u's string + c) that is in the trie: follow u's
                // failure chain until some node has a c-child (KMP's "fall back" step).
                int f = fail[u];
                while (f != 0 && !next.get(f).containsKey(c)) f = fail[f];
                Integer cand = next.get(f).get(c);
                fail[v] = (cand != null && cand != v) ? cand : 0;
                outLink[v] = out.get(fail[v]).isEmpty() ? outLink[fail[v]] : fail[v];
                queue.add(v);
            }
        }
        built = true;
        return this;
    }

    /** Every occurrence of every pattern in {@code text}, ordered by end position. */
    public List<Match<T>> findAll(CharSequence text) {
        if (!built) throw new IllegalStateException("call build() first");
        List<Match<T>> matches = new ArrayList<>();
        int state = 0;
        for (int i = 0; i < text.length(); i++) {
            char c = Character.toLowerCase(text.charAt(i));
            while (state != 0 && !next.get(state).containsKey(c)) state = fail[state];
            Integer to = next.get(state).get(c);
            state = to == null ? 0 : to;
            for (int u = out.get(state).isEmpty() ? outLink[state] : state; u != -1; u = outLink[u]) {
                for (int p : out.get(u)) {
                    int len = patterns.get(p).length();
                    matches.add(new Match<>(i + 1 - len, i + 1, patterns.get(p), payloads.get(p)));
                }
            }
        }
        return matches;
    }

    public int patternCount() { return patterns.size(); }

    public int nodeCount() { return next.size(); }

    private int newNode() {
        next.add(new HashMap<>(4));
        out.add(new ArrayList<>(1));
        return next.size() - 1;
    }
}
