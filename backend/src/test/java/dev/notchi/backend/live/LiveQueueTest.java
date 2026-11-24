package dev.notchi.backend.live;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

import static dev.notchi.backend.live.LiveActivity.State.*;
import static org.junit.jupiter.api.Assertions.*;

class LiveQueueTest {

    private final AtomicLong now = new AtomicLong(1_000_000);

    private LiveQueue queue() {
        return new LiveQueue(new EventDeduplicator(1_000, 0.01, 60_000), now::get);
    }

    private static LiveQueue.Event ev(String eventId, String id, LiveActivity.State s, long ttl) {
        return new LiveQueue.Event(eventId, id, id, null, s, null, null, null, ttl);
    }

    private static List<String> ids(List<LiveActivity> list) {
        return list.stream().map(LiveActivity::id).toList();
    }

    @Test
    @DisplayName("needs-you, then running, then failed, then done; newest first within a state")
    void urgencyOrder() {
        LiveQueue q = queue();
        q.ingest(ev("1", "done-a", DONE, 0), 10);
        now.addAndGet(10);
        q.ingest(ev("2", "build", RUNNING, 0), 10);
        now.addAndGet(10);
        q.ingest(ev("3", "tests", FAILED, 0), 10);
        now.addAndGet(10);
        q.ingest(ev("4", "deploy", RUNNING, 0), 10);
        now.addAndGet(10);
        q.ingest(ev("5", "claude", ATTENTION, 0), 10);
        assertEquals(List.of("claude", "deploy", "build", "tests", "done-a"), ids(q.top(10)));
        assertEquals(List.of("claude", "deploy"), ids(q.top(2)));
    }

    @Test
    @DisplayName("an update re-prioritises the same activity instead of adding a row")
    void updateMovesActivity() {
        LiveQueue q = queue();
        q.ingest(ev("1", "claude", RUNNING, 0), 10);
        q.ingest(ev("2", "deploy", RUNNING, 0), 10);
        now.addAndGet(5);
        q.ingest(ev("3", "claude", ATTENTION, 0), 10);
        assertEquals(List.of("claude", "deploy"), ids(q.top(10)));
        now.addAndGet(5);
        q.ingest(ev("4", "claude", DONE, 0), 10);
        assertEquals(List.of("deploy", "claude"), ids(q.top(10)));
        assertEquals(2, q.size());
    }

    @Test
    @DisplayName("activities leave when their time-to-live runs out (expiry heap)")
    void expiry() {
        LiveQueue q = queue();
        q.ingest(ev("1", "done", DONE, 6), 10);
        q.ingest(ev("2", "build", RUNNING, 0), 10);       // ttl 0 = stays until ended
        now.addAndGet(5_999);
        assertEquals(2, q.size());
        now.addAndGet(1);
        assertEquals(List.of("build"), ids(q.top(10)));
        assertTrue(q.end("build"));
        assertFalse(q.end("build"));
        assertEquals(0, q.size());
    }

    @Test
    @DisplayName("a repeated event id is dropped and does not touch the queue")
    void duplicateIgnored() {
        LiveQueue q = queue();
        assertTrue(q.ingest(ev("evt-1", "deploy", RUNNING, 0), 10).accepted());
        now.addAndGet(100);
        q.ingest(ev("evt-2", "claude", RUNNING, 0), 10);
        now.addAndGet(100);
        LiveQueue.Result r = q.ingest(ev("evt-1", "deploy", RUNNING, 0), 10);
        assertFalse(r.accepted());
        assertEquals(EventDeduplicator.Verdict.DUPLICATE, r.verdict());
        // Had it been accepted, deploy (newer) would now be first.
        assertEquals(List.of("claude", "deploy"), ids(r.top()));
    }

    @Test
    @DisplayName("events without an id are fingerprinted: same content within 2 s is a duplicate")
    void fingerprintWindow() {
        LiveQueue q = queue();
        now.set(10_000);
        assertTrue(q.ingest(ev(null, "deploy", RUNNING, 0), 10).accepted());
        now.set(11_500);                                     // same 2-second bucket
        assertFalse(q.ingest(ev(null, "deploy", RUNNING, 0), 10).accepted());
        now.set(12_100);                                     // next bucket: a genuine new event
        assertTrue(q.ingest(ev(null, "deploy", RUNNING, 0), 10).accepted());
    }

    @Test
    @DisplayName("a quick change back (running → attention → running) is never mistaken for a repeat")
    void changeBackIsApplied() {
        LiveQueue q = queue();
        now.set(20_000);
        long v0 = q.version();
        assertTrue(q.ingest(ev(null, "claude", RUNNING, 0), 10).accepted());
        now.set(20_300);
        assertTrue(q.ingest(ev(null, "claude", ATTENTION, 0), 10).accepted());
        now.set(20_600);                                     // same 2-second bucket as the first event
        LiveQueue.Result back = q.ingest(ev(null, "claude", RUNNING, 0), 10);
        assertTrue(back.accepted());
        assertEquals(RUNNING, q.top(1).get(0).state());
        assertEquals(v0 + 3, back.version());               // every accepted change bumps the version
        assertFalse(q.ingest(ev(null, "claude", RUNNING, 0), 10).accepted());   // an exact repeat still is one
    }

    @Test
    @DisplayName("boundary: the queue refuses a new activity when full, without remembering the event")
    void capacityLimit() {
        LiveQueue q = new LiveQueue(new EventDeduplicator(100_000, 0.01, 60_000), now::get);
        for (int i = 0; i < LiveQueue.MAX_ACTIVITIES; i++) q.ingest(ev("e" + i, "a" + i, RUNNING, 0), 1);
        assertThrows(IllegalStateException.class, () -> q.ingest(ev("extra", "new-one", RUNNING, 0), 1));
        assertTrue(q.ingest(ev("upd", "a5", ATTENTION, 0), 1).accepted());   // updates still work
        q.end("a0");
        assertTrue(q.ingest(ev("extra", "new-one", RUNNING, 0), 1).accepted()); // not a "duplicate"
    }
}
