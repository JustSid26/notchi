package dev.notchi.backend.bench;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Random;

/**
 * Writes the bundled sample data: synthetic Claude Code run durations for five terminal tabs.
 *
 * <p>Task durations are right-skewed (most runs are short, a few take very long), so each tab
 * draws from a log-normal distribution: seconds = median · e^(σ·Z), Z ~ N(0, 1). The medians
 * and spreads below are loosely based on the author's own Claude Code sessions. 1–2% of runs
 * are long outliers (a big refactor, a slow test suite). Fixed seed, so the file is reproducible:
 *
 * <pre>  java -cp target/classes dev.notchi.backend.bench.SampleDataGenerator src/main/resources/sample/durations.csv</pre>
 */
public final class SampleDataGenerator {

    record Tab(String name, double medianSeconds, double sigma, int runs) {}

    static final List<Tab> TABS = List.of(
            new Tab("crm", 140, 0.55, 240),
            new Tab("notchi", 75, 0.50, 260),
            new Tab("ml-pipeline", 420, 0.70, 120),
            new Tab("docs", 45, 0.45, 150),
            new Tab("infra", 210, 0.65, 130));

    public static void main(String[] args) throws IOException {
        Path out = Path.of(args.length > 0 ? args[0] : "src/main/resources/sample/durations.csv");
        Random rnd = new Random(20261124L);
        List<String> lines = new ArrayList<>();
        lines.add("key,seconds");
        for (Tab t : TABS) {
            for (int i = 0; i < t.runs; i++) {
                double s = t.medianSeconds * Math.exp(t.sigma * rnd.nextGaussian());
                if (rnd.nextDouble() < 0.015) s *= 4 + 4 * rnd.nextDouble();   // rare long run
                s = Math.max(3, Math.min(s, 6 * 3600));
                lines.add(t.name + "," + String.format(Locale.ROOT, "%.1f", s));
            }
        }
        Path dir = out.toAbsolutePath().getParent();
        if (dir != null) Files.createDirectories(dir);
        Files.write(out, lines, StandardCharsets.UTF_8);
        System.out.println("Wrote " + (lines.size() - 1) + " durations to " + out);
    }
}
