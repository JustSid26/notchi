package dev.notchi.backend.live;

import dev.notchi.backend.algo.heap.IndexedBinaryHeap;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.LongSupplier;

/**
 * The island's LIVE queue.
 *
 * <ul>
 *   <li>{@code byUrgency}: an indexed max-heap of activities ordered by
 *       {@link LiveActivity#URGENCY}. An update to one activity costs O(log n), and the
 *       island reads the top k in O(k log k) instead of re-sorting everything.</li>
 *   <li>{@code byExpiry}: a second indexed heap keyed by expiry time (soonest first), so
 *       finished activities leave on time without scanning the whole queue.</li>
 *   <li>{@code dedupe}: Bloom-filter screening of event ids, so a repeated event neither
 *       re-orders the queue nor re-announces itself.</li>
 * </ul>
 *
 * All public methods are synchronized; the HTTP server calls them from several threads.
 */
public final class LiveQueue {

    public static final int MAX_ACTIVITIES = 10_000;
    public static final long MAX_TTL_SECONDS = 7 * 24 * 3600;

    /** A validated incoming event. */
    public record Event(String eventId, String id, String title, String subtitle, LiveActivity.State state,
                        Double progress, String icon, String tint, long ttlSeconds) {}

    /**
     * What happened to an event. {@code top} is the queue's order (most urgent first) and
     * {@code version} counts changes to the queue, so a client can ignore an older order that
     * arrives after a newer one.
     */
    public record Result(EventDeduplicator.Verdict verdict, boolean accepted, List<LiveActivity> top, int size,
                         long version) {}

    /** The k most urgent activities plus the queue version they belong to. */
    public record Snapshot(List<LiveActivity> top, int size, long version) {}

    private final IndexedBinaryHeap<String, LiveActivity> byUrgency = new IndexedBinaryHeap<>(LiveActivity.URGENCY);
    private final IndexedBinaryHeap<String, Long> byExpiry = new IndexedBinaryHeap<>((a, b) -> Long.compare(b, a));
    private final EventDeduplicator dedupe;
    private final LongSupplier clock;
    private long version;

    public LiveQueue(EventDeduplicator dedupe, LongSupplier clock) {
        this.dedupe = dedupe;
        this.clock = clock;
    }

    public synchronized Result ingest(Event e, int topK) {
        long now = clock.getAsLong();
        expire(now);
        // Check capacity first, so a rejected event isn't remembered as "seen".
        if (!byUrgency.contains(e.id()) && byUrgency.size() >= MAX_ACTIVITIES) {
            throw new IllegalStateException("LIVE queue is full (" + MAX_ACTIVITIES + " activities)");
        }
        EventDeduplicator.Verdict verdict;
        if (e.eventId() != null) {
            // The sender's own id: any repeat is a retry or a replay, even if it would roll the
            // activity back (e.g. a late "running" after "done").
            verdict = dedupe.check(e.eventId(), now);
        } else {
            // No id: fall back to a content fingerprint, but only an event identical to what the
            // activity shows right now can be a repeat. A change (running → attention → running)
            // is always applied, however fast it happens.
            String fp = fingerprint(e, now);
            if (sameContent(byUrgency.get(e.id()), e)) {
                verdict = dedupe.check(fp, now);
            } else {
                dedupe.remember(fp, now);
                verdict = EventDeduplicator.Verdict.NEW;
            }
        }
        if (verdict == EventDeduplicator.Verdict.DUPLICATE) {
            return new Result(verdict, false, topValues(topK), byUrgency.size(), version);
        }
        long expires = e.ttlSeconds() > 0 ? now + e.ttlSeconds() * 1000 : 0;
        LiveActivity a = new LiveActivity(e.id(), e.title(), e.subtitle(), e.state(), e.progress(),
                e.icon(), e.tint(), now, expires);
        byUrgency.upsert(e.id(), a);
        if (expires > 0) byExpiry.upsert(e.id(), expires);
        else byExpiry.remove(e.id());
        version++;
        return new Result(verdict, true, topValues(topK), byUrgency.size(), version);
    }

    /** The k most urgent activities, most urgent first. */
    public synchronized List<LiveActivity> top(int k) {
        expire(clock.getAsLong());
        return topValues(k);
    }

    /** Like {@link #top} but with the size and version, read together under one lock. */
    public synchronized Snapshot snapshot(int k) {
        expire(clock.getAsLong());
        return new Snapshot(topValues(k), byUrgency.size(), version);
    }

    private List<LiveActivity> topValues(int k) {
        List<LiveActivity> out = new ArrayList<>(Math.min(k, byUrgency.size()));
        for (var e : byUrgency.topK(k)) out.add(e.getValue());
        return out;
    }

    public synchronized int size() {
        expire(clock.getAsLong());
        return byUrgency.size();
    }

    /** Removes an activity (e.g. `island end`). */
    public synchronized boolean end(String id) {
        byExpiry.remove(id);
        boolean removed = byUrgency.remove(id) != null;
        if (removed) version++;
        return removed;
    }

    public synchronized long version() { return version; }

    public synchronized Map<String, Object> stats() {
        expire(clock.getAsLong());
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Indexed binary heap (urgency) + indexed binary heap (expiry)");
        m.put("size", byUrgency.size());
        m.put("withExpiry", byExpiry.size());
        m.put("dedupe", dedupe.stats());
        return m;
    }

    public EventDeduplicator dedupe() { return dedupe; }

    /** Pops every activity whose expiry time has passed: O(e log n) for e expired. */
    private void expire(long now) {
        while (!byExpiry.isEmpty() && byExpiry.peek().getValue() <= now) {
            String id = byExpiry.poll().getKey();
            byUrgency.remove(id);
            version++;
        }
    }

    private static boolean sameContent(LiveActivity cur, Event e) {
        return cur != null && cur.state() == e.state() && cur.title().equals(e.title())
                && java.util.Objects.equals(cur.subtitle(), e.subtitle())
                && java.util.Objects.equals(cur.progress(), e.progress());
    }

    /**
     * Id for an event that didn't bring its own: its content plus a 2-second time bucket.
     * An event identical to the activity's current content within the same bucket is a
     * duplicate (hooks and scripts that fire twice); the same content later is a new event.
     */
    static String fingerprint(Event e, long now) {
        return String.join("|", e.id(), e.state().name(), e.title(),
                String.valueOf(e.subtitle()), String.valueOf(e.progress()))
                + "@" + (now / 2000);
    }
}
