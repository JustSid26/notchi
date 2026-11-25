package dev.notchi.backend.algo.text;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Substring search over a set of documents (clipboard clips, notes) with a suffix array.
 *
 * <p>The documents are lower-cased and joined with a separator character that never occurs
 * in a query, so no match can cross from one document into the next. Every suffix of that
 * text is sorted once; all suffixes that start with a query are then one contiguous block,
 * found with two binary searches.
 *
 * <p>Construction is prefix doubling: suffixes are sorted by their first 1, 2, 4, 8…
 * characters, each round a radix sort (two stable counting-sort passes, Unit 1) on the pair
 * (rank of first half, rank of second half). It stops as soon as all ranks are distinct.
 *
 * <pre>
 * build      O(n log n) time, O(n) extra ints    n = total characters
 * search     O(m log n + occ)                     m = query length
 * baseline   scan every document: O(n · m) naive, O(n + m) with KMP — per query
 * </pre>
 *
 * Immutable: rebuild when the documents change.
 */
public final class SuffixIndex {

    static final char SEPARATOR = '\u0000';

    private final String text;
    private final int[] sa;
    /** Start offset of each document in {@code text}, ascending. */
    private final int[] starts;

    public SuffixIndex(List<String> documents) {
        StringBuilder b = new StringBuilder();
        starts = new int[documents.size()];
        for (int d = 0; d < documents.size(); d++) {
            starts[d] = b.length();
            String doc = documents.get(d);
            for (int i = 0; i < doc.length(); i++) {
                char c = doc.charAt(i);
                b.append(c == SEPARATOR ? ' ' : Character.toLowerCase(c));
            }
            b.append(SEPARATOR);
        }
        text = b.toString();
        sa = buildSuffixArray(text);
    }

    public int documentCount() { return starts.length; }

    public int length() { return text.length(); }

    /**
     * Indices of the documents containing {@code query} (case-insensitive), ascending, at most
     * {@code limit} of them. An empty query matches nothing.
     */
    public List<Integer> search(String query, int limit) {
        String q = lower(query);
        if (q.isEmpty() || q.indexOf(SEPARATOR) >= 0 || sa.length == 0) return List.of();
        int lo = lowerBound(q), hi = upperBound(q);
        boolean[] seen = new boolean[starts.length];
        List<Integer> docs = new ArrayList<>();
        for (int i = lo; i < hi; i++) {
            int d = documentOf(sa[i]);
            if (!seen[d]) {
                seen[d] = true;
                docs.add(d);
            }
        }
        docs.sort(null);
        return docs.size() > limit ? docs.subList(0, limit) : docs;
    }

    /** Number of occurrences of {@code query} across all documents. */
    public int count(String query) {
        String q = lower(query);
        if (q.isEmpty() || sa.length == 0) return 0;
        return upperBound(q) - lowerBound(q);
    }

    /** Lower-cases one character at a time, exactly as the documents were (so İ, Σ… match). */
    private static String lower(String s) {
        StringBuilder b = new StringBuilder(s.length());
        for (int i = 0; i < s.length(); i++) b.append(Character.toLowerCase(s.charAt(i)));
        return b.toString();
    }

    // ---- search -------------------------------------------------------------------------

    /** Compares the suffix at {@code pos} with q, looking at no more than |q| characters. */
    private int compare(int pos, String q) {
        int n = Math.min(q.length(), text.length() - pos);
        for (int i = 0; i < n; i++) {
            char a = text.charAt(pos + i), b = q.charAt(i);
            if (a != b) return a < b ? -1 : 1;
        }
        return n == q.length() ? 0 : -1;   // the suffix ran out first: it sorts before q
    }

    /** First suffix-array slot whose suffix is ≥ q. */
    private int lowerBound(String q) {
        int lo = 0, hi = sa.length;
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            if (compare(sa[mid], q) < 0) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    /** First suffix-array slot whose suffix doesn't start with q and is > q. */
    private int upperBound(String q) {
        int lo = 0, hi = sa.length;
        while (lo < hi) {
            int mid = (lo + hi) >>> 1;
            if (compare(sa[mid], q) <= 0) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    private int documentOf(int pos) {
        int i = Arrays.binarySearch(starts, pos);
        return i >= 0 ? i : -i - 2;
    }

    // ---- construction --------------------------------------------------------------------

    /** Suffix array of s by prefix doubling with radix (counting) sort. Package-private for tests. */
    static int[] buildSuffixArray(String s) {
        int n = s.length();
        int[] sa = new int[n];
        if (n == 0) return sa;
        int[] rank = new int[n], tmp = new int[n], second = new int[n];

        // Round 0: rank by single character. Compress the characters actually used so the
        // counting sort array stays small even for Unicode text.
        char[] distinct = s.toCharArray();
        Arrays.sort(distinct);
        int m = 0;
        for (int i = 0; i < distinct.length; i++) {
            if (i == 0 || distinct[i] != distinct[i - 1]) distinct[m++] = distinct[i];
        }
        for (int i = 0; i < n; i++) rank[i] = Arrays.binarySearch(distinct, 0, m, s.charAt(i));
        countingSort(identity(n), rank, sa, m);
        int classes = m;

        for (int k = 1; k < n; k <<= 1) {
            // Order by the second key (rank of the suffix starting k later; past the end = lowest):
            // suffixes without a second half first, then the others in the current sa order.
            int p = 0;
            for (int i = n - k; i < n; i++) second[p++] = i;
            for (int i = 0; i < n; i++) if (sa[i] >= k) second[p++] = sa[i] - k;
            // Stable counting sort by the first key finishes the radix sort.
            countingSort(second, rank, sa, classes);

            tmp[sa[0]] = 0;
            classes = 1;
            for (int i = 1; i < n; i++) {
                int a = sa[i - 1], b = sa[i];
                int a2 = a + k < n ? rank[a + k] : -1, b2 = b + k < n ? rank[b + k] : -1;
                if (rank[a] != rank[b] || a2 != b2) classes++;
                tmp[b] = classes - 1;
            }
            int[] t = rank; rank = tmp; tmp = t;
            if (classes == n) break;   // every suffix has a distinct rank: fully sorted
        }
        return sa;
    }

    /** Stable counting sort of {@code order} by key[order[i]] (keys in 0..range-1) into {@code out}. */
    private static void countingSort(int[] order, int[] key, int[] out, int range) {
        int[] count = new int[range + 1];
        for (int idx : order) count[key[idx] + 1]++;
        for (int i = 1; i <= range; i++) count[i] += count[i - 1];
        for (int idx : order) out[count[key[idx]]++] = idx;
    }

    private static int[] identity(int n) {
        int[] a = new int[n];
        for (int i = 0; i < n; i++) a[i] = i;
        return a;
    }
}
