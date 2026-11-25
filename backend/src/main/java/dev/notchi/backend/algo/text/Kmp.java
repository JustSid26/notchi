package dev.notchi.backend.algo.text;

import java.util.ArrayList;
import java.util.List;

/**
 * Knuth–Morris–Pratt single-pattern search. Used as the baseline for {@link AhoCorasick}
 * (run once per pattern) and for {@link SuffixIndex} (scan every document).
 *
 * <pre>
 * prefix function   O(m)
 * search            O(n + m), never re-reads a text character
 * </pre>
 */
public final class Kmp {

    private Kmp() {}

    /** pi[i] = length of the longest proper prefix of p[0..i] that is also a suffix of it. */
    public static int[] prefixFunction(String p) {
        int[] pi = new int[p.length()];
        for (int i = 1, k = 0; i < p.length(); i++) {
            while (k > 0 && p.charAt(i) != p.charAt(k)) k = pi[k - 1];
            if (p.charAt(i) == p.charAt(k)) k++;
            pi[i] = k;
        }
        return pi;
    }

    /** Start positions of every (possibly overlapping) occurrence of {@code pattern} in {@code text}. */
    public static List<Integer> findAll(String text, String pattern) {
        if (pattern.isEmpty()) throw new IllegalArgumentException("pattern must not be empty");
        List<Integer> hits = new ArrayList<>();
        int[] pi = prefixFunction(pattern);
        for (int i = 0, k = 0; i < text.length(); i++) {
            while (k > 0 && text.charAt(i) != pattern.charAt(k)) k = pi[k - 1];
            if (text.charAt(i) == pattern.charAt(k)) k++;
            if (k == pattern.length()) {
                hits.add(i - k + 1);
                k = pi[k - 1];
            }
        }
        return hits;
    }

    /** True if {@code pattern} occurs in {@code text}. */
    public static boolean contains(String text, String pattern) {
        int[] pi = prefixFunction(pattern);
        for (int i = 0, k = 0; i < text.length(); i++) {
            while (k > 0 && text.charAt(i) != pattern.charAt(k)) k = pi[k - 1];
            if (text.charAt(i) == pattern.charAt(k)) k++;
            if (k == pattern.length()) return true;
        }
        return false;
    }
}
