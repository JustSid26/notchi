package dev.notchi.backend.activity;

import dev.notchi.backend.algo.dsu.DisjointSet;
import dev.notchi.backend.json.Json;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

/**
 * Workspaces: groups of apps you keep using together, found from screen time.
 *
 * <ol>
 *   <li>Cut the last {@value #DAYS} days into 15-minute blocks; for each block, the apps that
 *       were in front for at least a minute (segment-tree range sums in {@link ScreenTime}).</li>
 *   <li>Count, for every pair of apps, the blocks they share.</li>
 *   <li>Leave out system apps (Finder, Notchi, System Settings…).</li>
 *   <li>Join two apps (union–find) when they share at least {@value #MIN_SHARED} blocks and
 *       their Jaccard similarity (shared blocks ÷ blocks where either is used) is at least
 *       0.4. A browser used with everything has a low similarity to each single app, so it
 *       can't chain "coding" and "design" into one group.</li>
 *   <li>Every set with two or more apps is a workspace. An app left on its own is then added
 *       to each workspace it is used with in at least half of that workspace's blocks, so
 *       Chrome can belong to both "coding" and "design".</li>
 * </ol>
 */
public final class Workspaces {

    public static final int DAYS = 14;
    public static final int BLOCK_MINUTES = 15;
    public static final int MIN_SECONDS = 60;
    public static final int MIN_SHARED = 3;
    public static final double MIN_OVERLAP = 0.5;
    /** Jaccard similarity needed to join two apps: shared blocks ÷ blocks where either is used. */
    public static final double MIN_JACCARD = 0.4;
    public static final int MAX_APPS = 6;

    static final Set<String> ALWAYS_HUBS = Set.of("com.apple.finder", "dev.notchi.app", "com.apple.systempreferences",
            "com.apple.loginwindow", "com.apple.dock", "com.apple.Spotlight", "com.apple.controlcenter",
            "com.apple.notificationcenterui", "com.apple.ScreenSaver.Engine");

    private final ScreenTime screenTime;
    private final Path dismissedFile;
    private final Set<String> dismissed = new LinkedHashSet<>();
    private Map<String, Object> lastStats = Map.of();

    public Workspaces(ScreenTime screenTime, Path dismissedFile) {
        this.screenTime = screenTime;
        this.dismissedFile = dismissedFile;
        if (dismissedFile != null && Files.exists(dismissedFile)) load();
    }

    public synchronized Map<String, Object> suggest(int utcOffsetMinutes) {
        LocalDate from = screenTime.today(ScreenTime.zone(utcOffsetMinutes)).minusDays(DAYS - 1);
        List<List<String>> blocks = screenTime.blocks(from, BLOCK_MINUTES, MIN_SECONDS);

        // Index apps, count blocks per app.
        Map<String, Integer> index = new HashMap<>();
        List<String> apps = new ArrayList<>();
        Map<String, Integer> blocksOf = new HashMap<>();
        for (List<String> b : blocks) {
            for (String a : b) {
                blocksOf.merge(a, 1, Integer::sum);
                if (!index.containsKey(a)) { index.put(a, apps.size()); apps.add(a); }
            }
        }
        Set<String> hubs = new TreeSet<>();
        for (String a : apps) if (ALWAYS_HUBS.contains(a)) hubs.add(a);

        // Pair counts over shared blocks (ignoring hubs).
        Map<Long, Integer> pairs = new HashMap<>();
        for (List<String> b : blocks) {
            List<Integer> ids = new ArrayList<>();
            for (String a : b) if (!hubs.contains(a)) ids.add(index.get(a));
            for (int i = 0; i < ids.size(); i++) {
                for (int j = i + 1; j < ids.size(); j++) {
                    int x = Math.min(ids.get(i), ids.get(j)), y = Math.max(ids.get(i), ids.get(j));
                    pairs.merge(((long) x << 32) | y, 1, Integer::sum);
                }
            }
        }

        // Union every strong pair.
        DisjointSet dsu = new DisjointSet(apps.size());
        int edges = 0;
        for (Map.Entry<Long, Integer> e : pairs.entrySet()) {
            int x = (int) (e.getKey() >>> 32), y = (int) (e.getKey() & 0xffffffffL);
            int together = e.getValue();
            int either = blocksOf.get(apps.get(x)) + blocksOf.get(apps.get(y)) - together;
            if (together >= MIN_SHARED && together >= MIN_JACCARD * either) {
                dsu.union(x, y);
                edges++;
            }
        }

        // Apps left on their own (and not system apps) may join the groups they're used with.
        Map<Integer, List<Integer>> sets = dsu.groups();
        Set<String> loners = new TreeSet<>();
        for (List<Integer> members : sets.values()) {
            if (members.size() == 1 && !hubs.contains(apps.get(members.get(0)))) loners.add(apps.get(members.get(0)));
        }

        // Sets of two or more apps become workspaces.
        Map<String, Long> totals = screenTime.totalsSince(from);
        List<Map<String, Object>> out = new ArrayList<>();
        for (List<Integer> members : sets.values()) {
            if (members.size() < 2) continue;
            List<String> group = new ArrayList<>();
            for (int i : members) group.add(apps.get(i));
            // Attach the shared apps this workspace really uses.
            Set<String> memberSet = new java.util.HashSet<>(group);
            int groupBlocks = 0;
            Map<String, Integer> with = new HashMap<>();
            for (List<String> b : blocks) {
                boolean active = false;
                for (String a : b) if (memberSet.contains(a)) { active = true; break; }
                if (!active) continue;
                groupBlocks++;
                for (String a : b) if (loners.contains(a)) with.merge(a, 1, Integer::sum);
            }
            for (Map.Entry<String, Integer> w : with.entrySet()) {
                if (w.getValue() >= MIN_SHARED && w.getValue() >= MIN_OVERLAP * groupBlocks) group.add(w.getKey());
            }
            group.sort((a, b) -> Long.compare(totals.getOrDefault(b, 0L), totals.getOrDefault(a, 0L)));
            List<String> top = group.size() > MAX_APPS ? group.subList(0, MAX_APPS) : group;
            String signature = String.join("|", new TreeSet<>(top));
            if (dismissed.contains(signature)) continue;
            long time = 0;
            List<Map<String, Object>> list = new ArrayList<>();
            for (String a : top) {
                long t = totals.getOrDefault(a, 0L);
                time += t;
                Map<String, Object> app = new LinkedHashMap<>();
                app.put("app", a);
                app.put("name", screenTime.name(a));
                app.put("seconds", t);
                list.add(app);
            }
            Map<String, Object> w = new LinkedHashMap<>();
            w.put("name", screenTime.name(top.get(0)) + " + " + screenTime.name(top.get(1))
                    + (top.size() > 2 ? " + " + (top.size() - 2) : ""));
            w.put("signature", signature);
            w.put("apps", list);
            w.put("seconds", time);
            out.add(w);
        }
        out.sort((a, b) -> Long.compare((Long) b.get("seconds"), (Long) a.get("seconds")));

        Map<String, Object> stats = new LinkedHashMap<>();
        stats.put("algorithm", "Union–find (disjoint sets) over apps used in the same 15-minute blocks");
        stats.put("blocks", blocks.size());
        stats.put("apps", apps.size());
        stats.put("hubsIgnored", new ArrayList<>(hubs));
        stats.put("unpairedApps", new ArrayList<>(loners));
        stats.put("strongPairs", edges);
        stats.put("sets", dsu.components());
        lastStats = stats;

        Map<String, Object> m = new LinkedHashMap<>(stats);
        m.put("workspaces", out.size() > 6 ? out.subList(0, 6) : out);
        return m;
    }

    /** Hides a suggestion ("not a workspace"). */
    public synchronized void dismiss(List<String> apps) {
        if (apps == null || apps.size() < 2) throw new IllegalArgumentException("'apps' needs at least two apps");
        dismissed.add(String.join("|", new TreeSet<>(apps)));
        save();
    }

    public synchronized Map<String, Object> stats() { return lastStats; }

    private void save() {
        if (dismissedFile == null) return;
        try {
            Path dir = dismissedFile.toAbsolutePath().getParent();
            if (dir != null) Files.createDirectories(dir);
            Files.writeString(dismissedFile, Json.write(new ArrayList<>(dismissed)), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException("couldn't save dismissed workspaces", e);
        }
    }

    private void load() {
        try {
            if (Json.parse(Files.readString(dismissedFile, StandardCharsets.UTF_8)) instanceof List<?> l) {
                for (Object o : l) if (o instanceof String s) dismissed.add(s);
            }
        } catch (IOException | Json.ParseException e) {
            System.err.println("[notchi-backend] couldn't read " + dismissedFile + ": " + e.getMessage());
        }
    }
}
