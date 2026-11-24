package dev.notchi.backend.live;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static dev.notchi.backend.live.EventDeduplicator.Verdict.*;
import static org.junit.jupiter.api.Assertions.*;

class EventDeduplicatorTest {

    @Test
    @DisplayName("new → NEW without an exact lookup; repeat → DUPLICATE")
    void basicFlow() {
        EventDeduplicator d = new EventDeduplicator(1_000, 0.01, 60_000);
        assertEquals(NEW, d.check("a", 0));
        assertEquals(DUPLICATE, d.check("a", 10));
        assertEquals(NEW, d.check("b", 20));
        assertEquals(1L, d.stats().get("duplicatesDropped"));
        assertEquals(2L, d.stats().get("exactLookupsSkipped"));
    }

    @Test
    @DisplayName("a Bloom false positive never drops a genuinely new event")
    void falsePositivesAreConfirmed() {
        // A deliberately tiny, overloaded filter so false positives are frequent.
        EventDeduplicator d = new EventDeduplicator(10, 0.5, 60_000);
        int accepted = 0;
        for (int i = 0; i < 5_000; i++) {
            if (d.check("evt-" + i, i) != DUPLICATE) accepted++;
        }
        assertEquals(5_000, accepted, "every distinct event must get through");
        assertTrue((long) d.stats().get("falsePositives") >= 0);
    }

    @Test
    @DisplayName("ids older than the retention window are accepted again")
    void retention() {
        EventDeduplicator d = new EventDeduplicator(1_000, 0.01, 1_000);
        assertEquals(NEW, d.check("x", 0));
        assertEquals(DUPLICATE, d.check("x", 1_000));
        assertEquals(NEW, d.check("x", 2_001));
        assertEquals(1L, d.stats().get("expiredRepeats"));
    }

    @Test
    @DisplayName("the filter rebuilds and grows once it reaches capacity, without losing ids")
    void rebuildsWhenFull() {
        EventDeduplicator d = new EventDeduplicator(100, 0.01, 1_000_000);
        // NEW or NEW_AFTER_FALSE_POSITIVE are both fine; a new id must just never be a DUPLICATE.
        for (int i = 0; i < 1_000; i++) assertNotEquals(DUPLICATE, d.check("e" + i, i));
        assertTrue((long) d.stats().get("rebuilds") > 1);
        assertTrue(d.capacity() >= 1_000);
        for (int i = 0; i < 1_000; i++) assertEquals(DUPLICATE, d.check("e" + i, 2_000));
        assertTrue(d.filter().expectedFalsePositiveRate() < 0.02);
    }

    @Test
    @DisplayName("invalid settings and blank ids are rejected")
    void validation() {
        assertThrows(IllegalArgumentException.class, () -> new EventDeduplicator(5, 0.01, 1000));
        assertThrows(IllegalArgumentException.class, () -> new EventDeduplicator(100, 0.9, 1000));
        assertThrows(IllegalArgumentException.class, () -> new EventDeduplicator(100, 0.01, 0));
        EventDeduplicator d = new EventDeduplicator(100, 0.01, 1000);
        assertThrows(IllegalArgumentException.class, () -> d.check(" ", 0));
        assertThrows(IllegalArgumentException.class, () -> d.check(null, 0));
    }
}
