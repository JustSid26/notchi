package dev.notchi.backend.activity;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

import static org.junit.jupiter.api.Assertions.*;

class WorkspacesTest {

    private static final ZoneOffset IST = ZoneOffset.ofHoursMinutes(5, 30);
    private static final long NOW = LocalDateTime.of(2026, 11, 25, 23, 0).toInstant(IST).toEpochMilli();

    @SuppressWarnings("unchecked")
    private static List<Set<String>> groups(Map<String, Object> result) {
        return ((List<Map<String, Object>>) result.get("workspaces")).stream()
                .map(w -> ((List<Map<String, Object>>) w.get("apps")).stream()
                        .map(a -> (String) a.get("app")).collect(Collectors.toSet()))
                .toList();
    }

    @Test
    @DisplayName("edge: no screen time, no workspaces")
    void empty() {
        ScreenTime st = new ScreenTime(null, () -> NOW);
        assertEquals(List.of(), groups(new Workspaces(st, null).suggest(330)));
    }

    @Test
    @DisplayName("the demo week yields a coding and a design workspace; Finder is ignored as a hub")
    void demoWeek() {
        ScreenTime st = new ScreenTime(null, () -> NOW);
        DemoActivity.fill(st, NOW, 330);
        Map<String, Object> r = new Workspaces(st, null).suggest(330);
        List<Set<String>> g = groups(r);
        assertTrue(g.contains(Set.of("com.apple.dt.Xcode", "com.googlecode.iterm2", "com.apple.Safari")), g.toString());
        assertTrue(g.contains(Set.of("com.figma.Desktop", "com.tinyspeck.slackmacgap", "com.google.Chrome")), g.toString());
        assertTrue(g.stream().noneMatch(s -> s.contains("com.apple.finder")));
        assertTrue(((List<?>) r.get("hubsIgnored")).contains("com.apple.finder"));
    }

    @Test
    @DisplayName("a browser used with everything joins both groups instead of merging them")
    void sharedBrowser() {
        ScreenTime st = new ScreenTime(null, () -> NOW);
        java.util.Random r = new java.util.Random(1);
        for (int d = 6; d >= 0; d--) {
            long base = LocalDateTime.of(2026, 11, 25, 0, 0).minusDays(d).toInstant(IST).toEpochMilli();
            long t = base + 9 * 3600_000L;
            for (String[] grp : new String[][]{{"xcode", "iterm", "chrome"}, {"figma", "slack", "chrome"}}) {
                long end = t + 3 * 3600_000L;
                while (t < end) {
                    String app = grp[r.nextInt(3)];
                    long len = (2 + r.nextInt(8)) * 60_000L;
                    st.addUnchecked(new ScreenTime.Span(app, app, t, t + len), 330);
                    t += len + 5_000;
                }
                t += 3600_000L;
            }
        }
        List<Set<String>> g = groups(new Workspaces(st, null).suggest(330));
        assertEquals(2, g.size(), g.toString());
        assertTrue(g.contains(Set.of("xcode", "iterm", "chrome")), g.toString());
        assertTrue(g.contains(Set.of("figma", "slack", "chrome")), g.toString());
    }

    @Test
    @DisplayName("apps used together only once are not grouped (needs 3 shared blocks)")
    void needsRepetition() {
        ScreenTime st = new ScreenTime(null, () -> NOW);
        long t = LocalDateTime.of(2026, 11, 25, 9, 0).toInstant(IST).toEpochMilli();
        st.add(List.of(new ScreenTime.Span("a", "A", t, t + 5 * 60_000),
                new ScreenTime.Span("b", "B", t + 5 * 60_000, t + 10 * 60_000)), 330);
        assertEquals(List.of(), groups(new Workspaces(st, null).suggest(330)));
    }

    @Test
    @DisplayName("a dismissed workspace isn't suggested again; dismissing needs two apps")
    void dismiss() {
        ScreenTime st = new ScreenTime(null, () -> NOW);
        DemoActivity.fill(st, NOW, 330);
        Workspaces w = new Workspaces(st, null);
        int before = groups(w.suggest(330)).size();
        w.dismiss(List.of("com.figma.Desktop", "com.tinyspeck.slackmacgap", "com.google.Chrome"));
        assertEquals(before - 1, groups(w.suggest(330)).size());
        assertThrows(IllegalArgumentException.class, () -> w.dismiss(List.of("only-one")));
    }
}
