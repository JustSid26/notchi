package dev.notchi.backend.json;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class JsonTest {

    @Test
    @DisplayName("parses objects, arrays, numbers, booleans, null and escapes")
    void parsesAllTypes() {
        Map<String, Object> m = Json.parseObject(
                "{\"a\":1,\"b\":-2.5e1,\"c\":[true,false,null],\"d\":\"x\\\"y\\n\\u00e9\",\"e\":{}}");
        assertEquals(1L, m.get("a"));
        assertEquals(-25.0, m.get("b"));
        assertEquals(java.util.Arrays.asList(true, false, null), m.get("c"));
        assertEquals("x\"y\né", m.get("d"));
        assertEquals(Map.of(), m.get("e"));
    }

    @Test
    @DisplayName("round-trips what it writes")
    void roundTrip() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("title", "Claude \"finished\"\t✓");
        m.put("n", 3L);
        m.put("p", 0.25);
        m.put("list", List.of(1L, "two"));
        assertEquals(m, Json.parse(Json.write(m)));
        assertEquals("{\"x\":null}", Json.write(Map.of("x", Double.NaN)));
        assertEquals("2", Json.write(2.0));
    }

    @Test
    @DisplayName("malformed input is rejected with a position")
    void malformed() {
        for (String bad : new String[]{"", "{", "{\"a\":}", "[1,]", "{\"a\" 1}", "tru", "\"open",
                "{\"a\":1} x", "01x", "-", "\"bad \\q escape\"", "1e999",
                "01", "1.", ".5", "1e", "+1", "\"\\u+041\"", "\"\\u12\""}) {
            assertThrows(Json.ParseException.class, () -> Json.parse(bad), bad);
        }
        assertThrows(Json.ParseException.class, () -> Json.parseObject("[1]"));
    }

    @Test
    @DisplayName("boundary: very deep nesting is refused instead of overflowing the stack")
    void depthLimit() {
        String deep = "[".repeat(10_000) + "]".repeat(10_000);
        assertThrows(Json.ParseException.class, () -> Json.parse(deep));
    }

    @Test
    @DisplayName("typed field access gives clear errors")
    void fields() {
        Json.Fields f = new Json.Fields(Json.parseObject("{\"s\":\"x\",\"n\":2,\"l\":[]}"));
        assertEquals("x", f.string("s"));
        assertEquals(2.0, f.number("n"));
        assertEquals(List.of(), f.list("l"));
        assertNull(f.optString("missing"));
        assertEquals("'n' must be a string",
                assertThrows(IllegalArgumentException.class, () -> f.string("n")).getMessage());
        assertEquals("'missing' is required",
                assertThrows(IllegalArgumentException.class, () -> f.number("missing")).getMessage());
    }
}
