package dev.notchi.backend.live;

import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * One row in the island's LIVE card: a build, a deploy, a Claude run, a timer…
 *
 * @param id        stable id chosen by the sender ("deploy", "claude-CRM", …)
 * @param title     what the island shows
 * @param subtitle  optional second line
 * @param state     running / attention / failed / done
 * @param progress  0..1, or null when unknown
 * @param icon      SF Symbol name (the Mac app draws it)
 * @param tint      colour name or #hex (the Mac app resolves it)
 * @param updated   epoch millis of the last accepted event
 * @param expires   epoch millis when it leaves the queue, or 0 for never
 */
public record LiveActivity(String id, String title, String subtitle, State state, Double progress,
                           String icon, String tint, long updated, long expires) {

    public enum State {
        DONE(0), FAILED(1), RUNNING(2), ATTENTION(3);

        /** Higher = more urgent. Needs-you first, then running, then failed, then finished. */
        public final int rank;

        State(int rank) { this.rank = rank; }

        public static State parse(String s) {
            if (s == null) throw new IllegalArgumentException("'state' is required");
            return switch (s.toLowerCase()) {
                case "running" -> RUNNING;
                case "attention" -> ATTENTION;
                case "failed" -> FAILED;
                case "done" -> DONE;
                default -> throw new IllegalArgumentException("'state' must be running, attention, failed or done");
            };
        }
    }

    /**
     * The LIVE queue's priority: compare(a, b) &gt; 0 when a is more urgent.
     * State rank first, then the most recently updated, then id (so ties are deterministic).
     */
    public static final Comparator<LiveActivity> URGENCY = Comparator
            .comparingInt((LiveActivity a) -> a.state.rank)
            .thenComparingLong(LiveActivity::updated)
            .thenComparing(LiveActivity::id, Comparator.reverseOrder());

    public Map<String, Object> toJson() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", id);
        m.put("title", title);
        if (subtitle != null) m.put("subtitle", subtitle);
        m.put("state", state.name().toLowerCase());
        m.put("rank", state.rank);
        if (progress != null) m.put("progress", progress);
        if (icon != null) m.put("icon", icon);
        if (tint != null) m.put("tint", tint);
        m.put("updated", updated);
        if (expires > 0) m.put("expires", expires);
        return m;
    }
}
