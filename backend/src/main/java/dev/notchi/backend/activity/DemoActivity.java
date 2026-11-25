package dev.notchi.backend.activity;

import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.Random;

/**
 * Synthetic screen time for demo mode: a week of realistic days, so the Activity page and
 * Workspaces have something to show on a fresh install. Fixed seed, so it's reproducible.
 *
 * <p>Each day has a coding block (Xcode, iTerm2, Safari), a design block (Figma, Slack,
 * Chrome), an evening block (Spotify, WhatsApp) and the odd Finder or Mail visit. Inside a
 * block the apps take turns in stretches of 2–12 minutes.
 */
public final class DemoActivity {

    private DemoActivity() {}

    record App(String id, String name) {}

    static final App XCODE = new App("com.apple.dt.Xcode", "Xcode");
    static final App ITERM = new App("com.googlecode.iterm2", "iTerm2");
    static final App SAFARI = new App("com.apple.Safari", "Safari");
    static final App FIGMA = new App("com.figma.Desktop", "Figma");
    static final App SLACK = new App("com.tinyspeck.slackmacgap", "Slack");
    static final App CHROME = new App("com.google.Chrome", "Google Chrome");
    static final App SPOTIFY = new App("com.spotify.client", "Spotify");
    static final App WHATSAPP = new App("net.whatsapp.WhatsApp", "WhatsApp");
    static final App FINDER = new App("com.apple.finder", "Finder");
    static final App MAIL = new App("com.apple.mail", "Mail");

    /** Fills {@code st} with the last 6 days plus today up to {@code now}. */
    public static void fill(ScreenTime st, long now, int utcOffsetMinutes) {
        ZoneOffset zone = ScreenTime.zone(utcOffsetMinutes);
        LocalDate today = Instant.ofEpochMilli(now).atOffset(zone).toLocalDate();
        Random r = new Random(20261125L);
        for (int d = 6; d >= 0; d--) {
            LocalDate day = today.minusDays(d);
            long base = day.atStartOfDay().toInstant(zone).toEpochMilli();
            block(st, r, base + hm(9, 20 + r.nextInt(30)), 150 + r.nextInt(60), now, utcOffsetMinutes, XCODE, ITERM, SAFARI);
            visit(st, r, base + hm(12, 40), MAIL, now, utcOffsetMinutes);
            block(st, r, base + hm(14, r.nextInt(30)), 120 + r.nextInt(70), now, utcOffsetMinutes, FIGMA, SLACK, CHROME);
            visit(st, r, base + hm(17, 30), FINDER, now, utcOffsetMinutes);
            block(st, r, base + hm(20, 10 + r.nextInt(30)), 50 + r.nextInt(40), now, utcOffsetMinutes, SPOTIFY, WHATSAPP);
        }
    }

    private static void block(ScreenTime st, Random r, long start, int minutes, long now, int tz, App... apps) {
        long t = start, end = start + minutes * 60_000L;
        App previous = null;
        while (t < end) {
            App a = apps[r.nextInt(apps.length)];
            if (a == previous) continue;
            long len = (2 + r.nextInt(11)) * 60_000L + r.nextInt(60) * 1000L;
            long stop = Math.min(Math.min(t + len, end), now);
            if (stop <= t) return;
            st.addUnchecked(new ScreenTime.Span(a.id(), a.name(), t, stop), tz);
            previous = a;
            t = stop + 5_000;
        }
    }

    private static void visit(ScreenTime st, Random r, long start, App a, long now, int tz) {
        long stop = Math.min(start + (1 + r.nextInt(4)) * 60_000L, now);
        if (stop > start) st.addUnchecked(new ScreenTime.Span(a.id(), a.name(), start, stop), tz);
    }

    private static long hm(int h, int m) { return (h * 60L + m) * 60_000L; }
}
