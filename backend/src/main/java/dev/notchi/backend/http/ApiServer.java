package dev.notchi.backend.http;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import dev.notchi.backend.json.Json;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * A tiny JSON-over-HTTP server on the JDK's built-in {@link HttpServer}.
 *
 * <p>It only listens on 127.0.0.1: the Notchi app on the same Mac is the only client.
 * Handlers return a value that is written as JSON with status 200; exceptions become JSON
 * errors with a matching status:
 * <pre>
 *   malformed JSON, IllegalArgumentException  → 400
 *   NoSuchElementException, unknown route     → 404
 *   wrong method                              → 405
 *   missing or wrong token (when one is set)   → 401
 *   request with an Origin or a foreign Host  → 403
 *   IllegalStateException                     → 409
 *   body over 2 MB                            → 413
 *   anything else                             → 500 (details go to the log, not the client)
 * </pre>
 */
public final class ApiServer {

    public static final int MAX_BODY_BYTES = 2 * 1024 * 1024;

    /** An error with an explicit HTTP status. */
    public static final class HttpError extends RuntimeException {
        public final int status;

        public HttpError(int status, String message) {
            super(message);
            this.status = status;
        }
    }

    /** One incoming request, already decoded. */
    public record Request(String method, String path, Map<String, String> query, String body, List<String> params) {

        public Map<String, Object> json() {
            if (body == null || body.isBlank()) throw new IllegalArgumentException("request body is required");
            return Json.parseObject(body);
        }

        public Json.Fields fields() { return new Json.Fields(json()); }

        public String param(int i) { return params.get(i); }

        public String query(String name) { return query.get(name); }

        public int intQuery(String name, int fallback) {
            String v = query.get(name);
            if (v == null || v.isEmpty()) return fallback;
            try {
                return Integer.parseInt(v);
            } catch (NumberFormatException ex) {
                throw new IllegalArgumentException("'" + name + "' must be a whole number");
            }
        }
    }

    @FunctionalInterface
    public interface Handler {
        Object handle(Request request) throws Exception;
    }

    private record Route(String method, Pattern pattern, Handler handler) {}

    private final List<Route> routes = new ArrayList<>();
    private byte[] token;
    private HttpServer server;
    private ExecutorService executor;

    /** Registers a route. Path segments like {id} match one URL segment. */
    public ApiServer route(String method, String path, Handler handler) {
        String regex = "^" + path.replaceAll("\\{[^/]+}", "([^/]+)") + "$";
        routes.add(new Route(method, Pattern.compile(regex), handler));
        return this;
    }

    /**
     * Requires every request except /api/health to carry {@code X-Notchi-Token: <token>}.
     * Notchi starts the backend with a random token kept in the Keychain, so other programs on
     * the Mac (including sandboxed apps that may only make network requests) can't read your
     * notes or clipboard. Without a token (a backend you started by hand) nothing is required.
     */
    public ApiServer requireToken(String token) {
        this.token = token == null || token.isBlank() ? null : token.getBytes(StandardCharsets.UTF_8);
        return this;
    }

    /** Starts listening on 127.0.0.1:port (port 0 picks a free one, for tests). */
    public void start(int port) throws IOException {
        server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), port), 0);
        server.createContext("/", this::dispatch);
        executor = Executors.newFixedThreadPool(4, r -> {
            Thread t = new Thread(r, "notchi-http");
            t.setDaemon(true);
            return t;
        });
        server.setExecutor(executor);
        server.start();
    }

    public int port() { return server.getAddress().getPort(); }

    public void stop() {
        if (server != null) server.stop(0);
        if (executor != null) executor.shutdownNow();
    }

    private void dispatch(HttpExchange ex) {
        int status = 200;
        Object payload;
        try {
            checkLocalClient(ex);
            String path = ex.getRequestURI().getRawPath();
            if (token != null && !path.equals("/api/health")) {
                String given = ex.getRequestHeaders().getFirst("X-Notchi-Token");
                if (given == null || !java.security.MessageDigest.isEqual(token, given.getBytes(StandardCharsets.UTF_8))) {
                    throw new HttpError(401, "missing or wrong X-Notchi-Token");
                }
            }
            String method = ex.getRequestMethod();
            Route match = null;
            List<String> params = List.of();
            boolean pathExists = false;
            for (Route r : routes) {
                Matcher m = r.pattern.matcher(path);
                if (!m.matches()) continue;
                pathExists = true;
                if (!r.method.equals(method)) continue;
                match = r;
                params = new ArrayList<>();
                // In a path, '+' is a literal plus (only query strings use it for spaces).
                for (int i = 1; i <= m.groupCount(); i++) params.add(decode(m.group(i).replace("+", "%2B")));
                break;
            }
            if (match == null) {
                throw pathExists ? new HttpError(405, "method " + method + " not allowed here")
                                 : new HttpError(404, "no such endpoint: " + method + " " + path);
            }
            String body = readBody(ex.getRequestBody());
            Request req = new Request(method, path, parseQuery(ex.getRequestURI().getRawQuery()), body, params);
            payload = match.handler.handle(req);
            if (payload == null) payload = Map.of("ok", true);
        } catch (HttpError e) {
            status = e.status;
            payload = error(status, e.getMessage());
        } catch (Json.ParseException e) {
            status = 400;
            payload = error(status, "malformed JSON: " + e.getMessage());
        } catch (IllegalArgumentException e) {
            status = 400;
            payload = error(status, e.getMessage());
        } catch (NoSuchElementException e) {
            status = 404;
            payload = error(status, e.getMessage());
        } catch (IllegalStateException e) {
            status = 409;
            payload = error(status, e.getMessage());
        } catch (OutOfMemoryError e) {
            status = 503;
            payload = error(status, "out of memory; try a smaller request");
        } catch (Exception e) {
            status = 500;
            payload = error(status, "internal error");
            System.err.println("[notchi-backend] " + ex.getRequestMethod() + " " + ex.getRequestURI() + " failed:");
            e.printStackTrace();
        }
        send(ex, status, payload);
    }

    /**
     * The backend is for the Notchi app and command-line tools on this Mac. Browsers send an
     * Origin header on cross-site requests, and a DNS-rebinding page arrives with a foreign Host,
     * so both are refused; that keeps web pages from writing to it.
     */
    private static void checkLocalClient(HttpExchange ex) {
        if (ex.getRequestHeaders().getFirst("Origin") != null) {
            throw new HttpError(403, "requests from web pages are not allowed");
        }
        String host = ex.getRequestHeaders().getFirst("Host");
        if (host != null) {
            String name = host.startsWith("[") ? host.substring(0, host.indexOf(']') + 1)
                                               : host.replaceFirst(":\\d+$", "");
            if (!name.equals("127.0.0.1") && !name.equalsIgnoreCase("localhost") && !name.equals("[::1]")) {
                throw new HttpError(403, "unexpected Host header");
            }
        }
    }

    private static Map<String, Object> error(int status, String message) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("status", status);
        m.put("error", message == null ? "error" : message);
        return m;
    }

    private static void send(HttpExchange ex, int status, Object payload) {
        try (ex) {
            byte[] bytes = Json.write(payload).getBytes(StandardCharsets.UTF_8);
            ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
            ex.sendResponseHeaders(status, bytes.length);
            try (OutputStream os = ex.getResponseBody()) {
                os.write(bytes);
            }
        } catch (IOException e) {
            // The client went away; nothing useful to do.
        }
    }

    private static String readBody(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) != -1) {
            out.write(buf, 0, n);
            if (out.size() > MAX_BODY_BYTES) throw new HttpError(413, "request body larger than 2 MB");
        }
        return out.toString(StandardCharsets.UTF_8);
    }

    static Map<String, String> parseQuery(String raw) {
        Map<String, String> q = new LinkedHashMap<>();
        if (raw == null || raw.isEmpty()) return q;
        for (String pair : raw.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            String k = decode(eq < 0 ? pair : pair.substring(0, eq));
            String v = eq < 0 ? "" : decode(pair.substring(eq + 1));
            q.put(k, v);
        }
        return q;
    }

    private static String decode(String s) {
        try {
            return URLDecoder.decode(s, StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("badly encoded URL");
        }
    }
}
