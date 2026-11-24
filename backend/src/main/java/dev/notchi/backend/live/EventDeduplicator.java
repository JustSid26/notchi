package dev.notchi.backend.live;

import dev.notchi.backend.algo.bloom.BloomFilter;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Screens incoming events for duplicates (retried webhooks, a hook registered twice, the
 * same `island push` fired again…) so they don't re-order the queue or re-announce a banner.
 *
 * <p>Two layers:
 * <ol>
 *   <li>A {@link BloomFilter} answers "definitely new" for almost every new event, so the
 *       authoritative event log is not consulted at all.</li>
 *   <li>When the filter says "possibly seen", the event log (an exact map of event id →
 *       first-seen time) decides. Only a confirmed match is dropped; a Bloom false positive
 *       is counted and the event goes through.</li>
 * </ol>
 *
 * <p>Ids stay in the log for {@code retentionMillis} (24 h by default); an id that comes back
 * after that counts as new again. When the filter has absorbed its design capacity it is
 * rebuilt from the ids still in the log, with capacity max(planned, 2 × log size). Doubling
 * like a dynamic array keeps rebuilds amortized O(1) per event, and keeps the real
 * false-positive rate near the target instead of creeping up as the filter fills.
 */
public final class EventDeduplicator {

    public enum Verdict {
        /** Bloom filter: definitely never seen. The exact log was not consulted. */
        NEW,
        /** Bloom filter said "possibly seen", but the exact log disagreed: a false positive. */
        NEW_AFTER_FALSE_POSITIVE,
        /** Seen before within the retention window, confirmed by the exact log. */
        DUPLICATE
    }

    private final long retentionMillis;
    private long planned;
    private double fpp;
    private long capacity;
    private BloomFilter bloom;
    /** The authoritative record: event id → last time it was accepted. Oldest first. */
    private final LinkedHashMap<String, Long> log = new LinkedHashMap<>();

    private long received, duplicates, definitelyNew, possiblySeen, falsePositives, expiredRepeats, rebuilds;

    public EventDeduplicator(long plannedKeys, double fpp, long retentionMillis) {
        if (retentionMillis <= 0) throw new IllegalArgumentException("retention must be > 0");
        this.retentionMillis = retentionMillis;
        configure(plannedKeys, fpp);
    }

    /** Resizes the filter for a new workload (e.g. from Notchi's settings) and re-adds the log. */
    public synchronized void configure(long plannedKeys, double fpp) {
        if (plannedKeys < 10 || plannedKeys > 50_000_000) {
            throw new IllegalArgumentException("expected events must be between 10 and 50,000,000");
        }
        if (!(fpp >= 0.0001 && fpp <= 0.5)) {
            throw new IllegalArgumentException("false-positive rate must be between 0.0001 and 0.5");
        }
        this.planned = plannedKeys;
        this.fpp = fpp;
        rebuildFilter();
    }

    public synchronized Verdict check(String eventId, long now) {
        if (eventId == null || eventId.isBlank()) throw new IllegalArgumentException("event id must not be blank");
        received++;
        if (!bloom.mightContain(eventId)) {
            definitelyNew++;
            record(eventId, now);
            return Verdict.NEW;
        }
        possiblySeen++;
        Long seenAt = log.get(eventId);
        if (seenAt != null && now - seenAt <= retentionMillis) {
            duplicates++;
            return Verdict.DUPLICATE;
        }
        if (seenAt != null) {
            expiredRepeats++;       // a real repeat, but outside the window: accept it again
        } else {
            falsePositives++;       // the filter was wrong; the exact log saved the event
        }
        record(eventId, now);
        return seenAt != null ? Verdict.NEW : Verdict.NEW_AFTER_FALSE_POSITIVE;
    }

    /**
     * Records an id without asking whether it was seen (used for content fingerprints of events
     * that change an activity, which by definition aren't repeats).
     */
    public synchronized void remember(String eventId, long now) {
        if (eventId == null || eventId.isBlank()) throw new IllegalArgumentException("event id must not be blank");
        record(eventId, now);
    }

    private void record(String id, long now) {
        log.remove(id);         // re-insert so the log stays in time order
        log.put(id, now);
        bloom.add(id);
        if (bloom.insertedCount() >= capacity) {
            prune(now);
            rebuildFilter();
        }
    }

    /** Drops log entries older than the retention window. Oldest come first, so stop early. */
    private void prune(long now) {
        Iterator<Map.Entry<String, Long>> it = log.entrySet().iterator();
        while (it.hasNext()) {
            if (now - it.next().getValue() > retentionMillis) it.remove();
            else break;
        }
    }

    private void rebuildFilter() {
        capacity = Math.max(planned, 2L * log.size());
        BloomFilter fresh = BloomFilter.forExpected(capacity, fpp);
        for (String id : log.keySet()) fresh.add(id);
        bloom = fresh;
        rebuilds++;
    }

    public synchronized Map<String, Object> stats() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("algorithm", "Bloom filter + exact event log");
        m.put("received", received);
        m.put("duplicatesDropped", duplicates);
        m.put("definitelyNew", definitelyNew);
        m.put("exactLookupsSkipped", definitelyNew);
        m.put("possiblySeen", possiblySeen);
        m.put("falsePositives", falsePositives);
        m.put("expiredRepeats", expiredRepeats);
        long negatives = definitelyNew + falsePositives;
        m.put("observedFalsePositiveRate", negatives == 0 ? 0.0 : (double) falsePositives / negatives);
        m.put("bits", bloom.bitCount());
        m.put("hashes", bloom.hashCount());
        m.put("bytes", bloom.sizeInBytes());
        m.put("keysInFilter", bloom.insertedCount());
        m.put("capacity", capacity);
        m.put("fillRatio", bloom.fillRatio());
        m.put("expectedFalsePositiveRate", bloom.expectedFalsePositiveRate());
        m.put("targetFalsePositiveRate", fpp);
        m.put("plannedKeys", planned);
        m.put("eventLogSize", log.size());
        m.put("rebuilds", rebuilds);
        return m;
    }

    /** For tests. */
    synchronized BloomFilter filter() { return bloom; }

    synchronized long capacity() { return capacity; }
}
