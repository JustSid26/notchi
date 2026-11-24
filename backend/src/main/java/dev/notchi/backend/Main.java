package dev.notchi.backend;

import dev.notchi.backend.http.ApiServer;
import dev.notchi.backend.http.NotchiApi;
import dev.notchi.backend.launcher.Launcher;
import dev.notchi.backend.live.EventDeduplicator;
import dev.notchi.backend.live.LiveQueue;
import dev.notchi.backend.stats.DurationStats;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.List;
import java.util.Random;
import java.util.concurrent.CountDownLatch;

/**
 * Starts the Notchi backend.
 *
 * <pre>
 *   java -jar target/notchi-backend.jar              # keeps history in ~/Library/Application Support/Notchi/backend
 *   java -jar target/notchi-backend.jar --demo       # in-memory, preloaded with the sample durations
 *   java -jar target/notchi-backend.jar --port 7341 --data /tmp/notchi
 * </pre>
 */
public final class Main {

    public static final int DEFAULT_PORT = 7340;

    public static void main(String[] args) throws Exception {
        int port = DEFAULT_PORT;
        Path data = Path.of(System.getProperty("user.home"), "Library", "Application Support", "Notchi", "backend");
        boolean demo = false;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--port" -> port = Integer.parseInt(value(args, ++i, "--port"));
                case "--data" -> data = Path.of(value(args, ++i, "--data"));
                case "--demo" -> demo = true;
                case "-h", "--help" -> {
                    System.out.println("usage: java -jar notchi-backend.jar [--port N] [--data DIR] [--demo]");
                    return;
                }
                default -> {
                    System.err.println("unknown option " + args[i] + " (try --help)");
                    System.exit(2);
                }
            }
        }
        if (port < 0 || port > 65535) throw new IllegalArgumentException("port must be 0..65535");

        DurationStats durations = new DurationStats(demo ? null : data.resolve("durations.csv"), new Random());
        if (demo) {
            int n = durations.importCsv(sampleDurations());
            System.out.println("Demo mode: loaded " + n + " sample Claude run durations (nothing is saved).");
        }
        Launcher launcher = new Launcher(demo ? null : data.resolve("launcher-uses.properties"));
        LiveQueue live = new LiveQueue(new EventDeduplicator(10_000, 0.01, 24 * 3600 * 1000L),
                System::currentTimeMillis);

        ApiServer server = new NotchiApi(live, launcher, durations).register(new ApiServer());
        server.start(port);
        System.out.println("Notchi backend " + NotchiApi.VERSION + " on http://127.0.0.1:" + server.port()
                + (demo ? "" : "  (data: " + data + ")"));

        CountDownLatch stop = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            server.stop();
            stop.countDown();
        }));
        stop.await();
    }

    /** The bundled sample: synthetic Claude run durations (see SampleDataGenerator). */
    static List<String> sampleDurations() throws IOException {
        try (InputStream in = Main.class.getResourceAsStream("/sample/durations.csv")) {
            if (in == null) throw new IOException("sample/durations.csv missing from the jar");
            return new String(in.readAllBytes(), StandardCharsets.UTF_8).lines().toList();
        }
    }

    private static String value(String[] args, int i, String flag) {
        if (i >= args.length) {
            System.err.println(flag + " needs a value");
            System.exit(2);
        }
        return args[i];
    }
}
