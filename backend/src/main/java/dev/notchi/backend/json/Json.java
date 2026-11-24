package dev.notchi.backend.json;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A small JSON reader/writer so the backend needs nothing but the JDK.
 *
 * <p>Parsing maps JSON to plain Java: objects → {@code LinkedHashMap<String,Object>},
 * arrays → {@code ArrayList<Object>}, strings → String, numbers → Long (integers that fit)
 * or Double, true/false → Boolean, null → null.
 *
 * <p>Writing accepts the same types plus any Number, Map, Collection, arrays of Object,
 * records-turned-maps, and {@code double}s (NaN/Infinity are written as null).
 */
public final class Json {

    private Json() {}

    /** Thrown for malformed JSON; the message says what and where. */
    public static final class ParseException extends RuntimeException {
        public ParseException(String message) { super(message); }
    }

    private static final int MAX_DEPTH = 64;

    // ---- parsing ----------------------------------------------------------------------

    public static Object parse(String text) {
        if (text == null) throw new ParseException("empty body");
        Parser p = new Parser(text);
        p.skipWs();
        if (p.pos >= text.length()) throw new ParseException("empty body");
        Object v = p.value(0);
        p.skipWs();
        if (p.pos != text.length()) throw p.error("unexpected trailing characters");
        return v;
    }

    /** Parses and requires a JSON object at the top level. */
    @SuppressWarnings("unchecked")
    public static Map<String, Object> parseObject(String text) {
        Object v = parse(text);
        if (!(v instanceof Map)) throw new ParseException("expected a JSON object");
        return (Map<String, Object>) v;
    }

    private static final class Parser {
        final String s;
        int pos;

        Parser(String s) { this.s = s; }

        ParseException error(String msg) {
            return new ParseException(msg + " at position " + pos);
        }

        void skipWs() {
            while (pos < s.length()) {
                char c = s.charAt(pos);
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') pos++;
                else break;
            }
        }

        Object value(int depth) {
            if (depth > MAX_DEPTH) throw error("nesting too deep");
            skipWs();
            if (pos >= s.length()) throw error("unexpected end of input");
            char c = s.charAt(pos);
            switch (c) {
                case '{': return object(depth);
                case '[': return array(depth);
                case '"': return string();
                case 't': return literal("true", Boolean.TRUE);
                case 'f': return literal("false", Boolean.FALSE);
                case 'n': return literal("null", null);
                default:
                    if (c == '-' || (c >= '0' && c <= '9')) return number();
                    throw error("unexpected character '" + c + "'");
            }
        }

        Object literal(String word, Object v) {
            if (!s.startsWith(word, pos)) throw error("invalid literal");
            pos += word.length();
            return v;
        }

        Map<String, Object> object(int depth) {
            Map<String, Object> m = new LinkedHashMap<>();
            pos++; // {
            skipWs();
            if (peek() == '}') { pos++; return m; }
            while (true) {
                skipWs();
                if (peek() != '"') throw error("expected a string key");
                String key = string();
                skipWs();
                if (peek() != ':') throw error("expected ':'");
                pos++;
                m.put(key, value(depth + 1));
                skipWs();
                char c = peek();
                pos++;
                if (c == '}') return m;
                if (c != ',') { pos--; throw error("expected ',' or '}'"); }
            }
        }

        List<Object> array(int depth) {
            List<Object> a = new ArrayList<>();
            pos++; // [
            skipWs();
            if (peek() == ']') { pos++; return a; }
            while (true) {
                a.add(value(depth + 1));
                skipWs();
                char c = peek();
                pos++;
                if (c == ']') return a;
                if (c != ',') { pos--; throw error("expected ',' or ']'"); }
            }
        }

        char peek() {
            if (pos >= s.length()) throw error("unexpected end of input");
            return s.charAt(pos);
        }

        String string() {
            pos++; // opening quote
            StringBuilder b = new StringBuilder();
            while (true) {
                if (pos >= s.length()) throw error("unterminated string");
                char c = s.charAt(pos++);
                if (c == '"') return b.toString();
                if (c == '\\') {
                    if (pos >= s.length()) throw error("unterminated escape");
                    char e = s.charAt(pos++);
                    switch (e) {
                        case '"' -> b.append('"');
                        case '\\' -> b.append('\\');
                        case '/' -> b.append('/');
                        case 'b' -> b.append('\b');
                        case 'f' -> b.append('\f');
                        case 'n' -> b.append('\n');
                        case 'r' -> b.append('\r');
                        case 't' -> b.append('\t');
                        case 'u' -> {
                            if (pos + 4 > s.length()) throw error("bad unicode escape");
                            int code = 0;
                            for (int i = 0; i < 4; i++) {
                                int d = Character.digit(s.charAt(pos + i), 16);
                                if (d < 0) throw error("bad unicode escape");
                                code = code * 16 + d;
                            }
                            b.append((char) code);
                            pos += 4;
                        }
                        default -> throw error("bad escape '\\" + e + "'");
                    }
                } else if (c < 0x20) {
                    throw error("control character in string");
                } else {
                    b.append(c);
                }
            }
        }

        /** RFC 8259 number: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)? */
        Object number() {
            int start = pos;
            if (pos < s.length() && s.charAt(pos) == '-') pos++;
            if (pos >= s.length() || !isDigit(s.charAt(pos))) throw error("invalid number");
            if (s.charAt(pos) == '0') pos++;
            else while (pos < s.length() && isDigit(s.charAt(pos))) pos++;
            boolean integer = true;
            if (pos < s.length() && s.charAt(pos) == '.') {
                integer = false;
                pos++;
                if (pos >= s.length() || !isDigit(s.charAt(pos))) throw error("digits expected after '.'");
                while (pos < s.length() && isDigit(s.charAt(pos))) pos++;
            }
            if (pos < s.length() && (s.charAt(pos) == 'e' || s.charAt(pos) == 'E')) {
                integer = false;
                pos++;
                if (pos < s.length() && (s.charAt(pos) == '+' || s.charAt(pos) == '-')) pos++;
                if (pos >= s.length() || !isDigit(s.charAt(pos))) throw error("digits expected in exponent");
                while (pos < s.length() && isDigit(s.charAt(pos))) pos++;
            }
            String t = s.substring(start, pos);
            if (integer) {
                try {
                    return Long.parseLong(t);
                } catch (NumberFormatException tooBig) {
                    // falls through: integers beyond a long become doubles
                }
            }
            double d = Double.parseDouble(t);
            if (Double.isInfinite(d)) throw error("number out of range");
            return d;
        }

        private static boolean isDigit(char c) { return c >= '0' && c <= '9'; }
    }

    // ---- writing ----------------------------------------------------------------------

    public static String write(Object value) {
        StringBuilder b = new StringBuilder();
        write(b, value, 0);
        return b.toString();
    }

    private static void write(StringBuilder b, Object v, int depth) {
        if (depth > MAX_DEPTH) throw new IllegalArgumentException("value nested too deeply");
        if (v == null) {
            b.append("null");
        } else if (v instanceof String str) {
            quote(b, str);
        } else if (v instanceof Boolean) {
            b.append(v);
        } else if (v instanceof Double || v instanceof Float) {
            double d = ((Number) v).doubleValue();
            if (Double.isNaN(d) || Double.isInfinite(d)) b.append("null");
            else if (d == Math.rint(d) && Math.abs(d) < 1e15) b.append((long) d);
            else b.append(d);
        } else if (v instanceof Number) {
            b.append(v);
        } else if (v instanceof Map<?, ?> map) {
            b.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> e : map.entrySet()) {
                if (!first) b.append(',');
                first = false;
                quote(b, String.valueOf(e.getKey()));
                b.append(':');
                write(b, e.getValue(), depth + 1);
            }
            b.append('}');
        } else if (v instanceof Collection<?> c) {
            b.append('[');
            boolean first = true;
            for (Object o : c) {
                if (!first) b.append(',');
                first = false;
                write(b, o, depth + 1);
            }
            b.append(']');
        } else if (v instanceof Object[] arr) {
            write(b, List.of(arr), depth);
        } else if (v instanceof Enum<?> e) {
            quote(b, e.name().toLowerCase());
        } else {
            quote(b, v.toString());
        }
    }

    private static void quote(StringBuilder b, String s) {
        b.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                case '\b' -> b.append("\\b");
                case '\f' -> b.append("\\f");
                default -> {
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
                }
            }
        }
        b.append('"');
    }

    // ---- typed access helpers for request bodies ---------------------------------------

    /** Reads typed fields from a parsed JSON object, with clear errors for bad requests. */
    public static final class Fields {
        private final Map<String, Object> m;

        public Fields(Map<String, Object> m) { this.m = m; }

        public boolean has(String k) { return m.containsKey(k) && m.get(k) != null; }

        public String string(String k) {
            Object v = m.get(k);
            if (v == null) throw new IllegalArgumentException("'" + k + "' is required");
            if (!(v instanceof String s)) throw new IllegalArgumentException("'" + k + "' must be a string");
            return s;
        }

        public String optString(String k) { return has(k) ? string(k) : null; }

        public double number(String k) {
            Object v = m.get(k);
            if (v == null) throw new IllegalArgumentException("'" + k + "' is required");
            if (!(v instanceof Number n)) throw new IllegalArgumentException("'" + k + "' must be a number");
            return n.doubleValue();
        }

        public Double optNumber(String k) { return has(k) ? number(k) : null; }

        @SuppressWarnings("unchecked")
        public List<Object> list(String k) {
            Object v = m.get(k);
            if (v == null) throw new IllegalArgumentException("'" + k + "' is required");
            if (!(v instanceof List)) throw new IllegalArgumentException("'" + k + "' must be an array");
            return (List<Object>) v;
        }
    }
}
