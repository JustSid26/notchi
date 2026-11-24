package dev.notchi.backend.http;

import dev.notchi.backend.json.Json;
import dev.notchi.backend.launcher.Launcher;
import dev.notchi.backend.live.EventDeduplicator;
import dev.notchi.backend.live.LiveQueue;
import dev.notchi.backend.stats.DurationStats;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.List;
import java.util.Map;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

/** End-to-end: real HTTP requests against a server on a random port. */
class ApiServerTest {

    private ApiServer server;
    private final HttpClient http = HttpClient.newHttpClient();

    @BeforeEach
    void start() throws Exception {
        LiveQueue live = new LiveQueue(new EventDeduplicator(1_000, 0.01, 60_000), System::currentTimeMillis);
        server = new NotchiApi(live, new Launcher(null), new DurationStats(null, new Random(1)))
                .register(new ApiServer());
        server.start(0);
    }

    @AfterEach
    void stop() { server.stop(); }

    private record Res(int status, Map<String, Object> body) {}

    private Res call(String method, String path, String body) throws Exception {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + server.port() + path));
        b.method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body));
        HttpResponse<String> r = http.send(b.build(), HttpResponse.BodyHandlers.ofString());
        return new Res(r.statusCode(), Json.parseObject(r.body()));
    }

    @Test
    @DisplayName("health lists the four algorithms")
    void health() throws Exception {
        Res r = call("GET", "/api/health", null);
        assertEquals(200, r.status);
        assertEquals("ok", r.body.get("status"));
        assertEquals(4, ((List<?>) r.body.get("algorithms")).size());
    }

    @Test
    @DisplayName("pushing events orders the LIVE queue and drops a repeated event id")
    void liveFlow() throws Exception {
        assertEquals(true, call("POST", "/api/live/events",
                "{\"id\":\"deploy\",\"title\":\"Deploying\",\"state\":\"running\",\"progress\":0.4,\"eventId\":\"e1\"}").body.get("accepted"));
        Res second = call("POST", "/api/live/events", "{\"id\":\"claude\",\"state\":\"attention\",\"eventId\":\"e2\"}");
        assertEquals(List.of("claude", "deploy"), second.body.get("order"));
        Res dup = call("POST", "/api/live/events", "{\"id\":\"deploy\",\"state\":\"running\",\"eventId\":\"e1\"}");
        assertEquals("duplicate", dup.body.get("verdict"));
        Res list = call("GET", "/api/live?limit=1", null);
        assertEquals(2L, list.body.get("size"));
        assertEquals(1, ((List<?>) list.body.get("items")).size());
        assertEquals(true, call("DELETE", "/api/live/deploy", null).body.get("removed"));
    }

    @Test
    @DisplayName("bad requests get 400 with a reason; unknown routes 404; wrong method 405")
    void errors() throws Exception {
        assertEquals(400, call("POST", "/api/live/events", "{\"id\":").status);
        Res bad = call("POST", "/api/live/events", "{\"id\":\"x\",\"state\":\"running\",\"progress\":3}");
        assertEquals(400, bad.status);
        assertEquals("'progress' must be between 0 and 1", bad.body.get("error"));
        assertEquals(400, call("POST", "/api/live/events", null).status);
        assertEquals(400, call("GET", "/api/live?limit=abc", null).status);
        assertEquals(404, call("GET", "/api/nothing", null).status);
        assertEquals(405, call("DELETE", "/api/health", null).status);
        assertEquals(404, call("POST", "/api/launcher/use", "{\"id\":\"ghost\"}").status);
        // A web page (it sends an Origin header) may not use the backend.
        HttpRequest fromPage = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + server.port() + "/api/durations"))
                .header("Origin", "https://evil.example")
                .POST(HttpRequest.BodyPublishers.ofString("{\"key\":\"x\",\"seconds\":5}")).build();
        assertEquals(403, http.send(fromPage, HttpResponse.BodyHandlers.ofString()).statusCode());
    }

    @Test
    @DisplayName("launcher: catalog upload, prefix search, launches re-rank")
    void launcher() throws Exception {
        Res up = call("PUT", "/api/launcher/catalog", "{\"items\":[" +
                "{\"id\":\"app:figma\",\"label\":\"Figma\",\"kind\":\"app\"}," +
                "{\"id\":\"app:finder\",\"label\":\"Finder\",\"kind\":\"app\"}," +
                "{\"id\":\"tab:1\",\"label\":\"CRM backend\",\"kind\":\"tab\"}]}");
        assertEquals(3L, up.body.get("indexed"));
        call("POST", "/api/launcher/use", "{\"id\":\"app:finder\"}");
        Res r = call("GET", "/api/launcher/search?q=fi&k=5", null);
        List<?> items = (List<?>) r.body.get("items");
        assertEquals("Finder", ((Map<?, ?>) items.get(0)).get("label"));
        assertEquals(2, items.size());
        // Items that can't be indexed are skipped and reported; the rest still work.
        Res partial = call("PUT", "/api/launcher/catalog", "{\"items\":[" +
                "{\"id\":\"a\",\"label\":\"Arc\",\"kind\":\"app\"}," +
                "{\"id\":\"r\",\"label\":\"🚀\",\"kind\":\"tab\"}," +
                "{\"id\":\"b\",\"label\":\"B\",\"kind\":\"robot\"}]}");
        assertEquals(1L, partial.body.get("indexed"));
        assertEquals(2L, partial.body.get("skipped"));
        assertEquals(400, call("PUT", "/api/launcher/catalog", "{\"items\":[42]}").status);
    }

    @Test
    @DisplayName("durations: record runs, then ask for the ETA")
    void durations() throws Exception {
        for (int i = 1; i <= 10; i++) {
            call("POST", "/api/durations", "{\"key\":\"crm\",\"seconds\":" + (i * 10) + "}");
        }
        Res r = call("GET", "/api/durations/summary?key=crm", null);
        assertEquals(true, r.body.get("enough"));
        assertEquals(50L, r.body.get("p50"));
        assertEquals(400, call("POST", "/api/durations", "{\"key\":\"crm\",\"seconds\":-1}").status);
        Res imp = call("POST", "/api/durations/import", "key,seconds\ndocs,5\ndocs,6\n");
        assertEquals(2L, imp.body.get("imported"));
    }

    @Test
    @DisplayName("lab endpoints run on user data and check against the baseline")
    void lab() throws Exception {
        Res sel = call("POST", "/api/lab/select", "{\"values\":[5,1,4,2,3],\"percentiles\":[50]}");
        Map<?, ?> first = (Map<?, ?>) ((List<?>) sel.body.get("results")).get(0);
        assertEquals(3L, first.get("value"));
        assertEquals(true, first.get("matchesSort"));
        Res bloom = call("POST", "/api/lab/bloom",
                "{\"expected\":100,\"fpp\":0.01,\"inserts\":[\"a\",\"b\"],\"queries\":[\"a\",\"zzz\"]}");
        assertEquals(7L, bloom.body.get("hashes"));
        assertEquals(400, call("POST", "/api/lab/select", "{\"values\":[]}").status);
    }
}
