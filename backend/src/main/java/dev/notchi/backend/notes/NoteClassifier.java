package dev.notchi.backend.notes;

import dev.notchi.backend.algo.text.AhoCorasick;

import java.time.DayOfWeek;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneOffset;
import java.time.temporal.TemporalAdjusters;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Sorts a piece of text (a note, or something you copied) into a category, and explains why.
 *
 * <p>Two kinds of evidence are scored per category:
 * <ul>
 *   <li><b>Cue words</b> ("password", "remind", "buy", "def ", "what if"…), all found in one
 *       pass by an {@link AhoCorasick} automaton, with word-boundary checks.</li>
 *   <li><b>Structure</b>, from a single scan of the tokens: URLs, e-mail addresses, phone
 *       numbers, secrets (known key prefixes, long high-entropy strings, a lone password-like
 *       token, the value after "password:" or "password is", and tokens or passwords inside
 *       URLs), a due time ("tomorrow at 5pm", "in 20 min", "friday morning"), and code
 *       punctuation.</li>
 * </ul>
 * The highest score wins; ties go to the earlier category in {@link Category} (a secret beats
 * everything). Plain text with no evidence stays a {@code NOTE}. Links, e-mails and phone
 * numbers found inside a secret are never reported, so nothing secret leaks into the reasons.
 *
 * <pre>
 * classify   O(n + z)  for n characters and z cue matches (one automaton pass + one token scan)
 * </pre>
 */
public final class NoteClassifier {

    public enum Category { CREDENTIAL, REMINDER, LINK, CONTACT, TODO, CODE, IDEA, NOTE }

    /**
     * A cue word: which category it supports, how strongly, whether it must be a whole word,
     * and whether a secret value may follow it ("password: …").
     */
    record Cue(Category category, double weight, boolean wordStart, boolean wordEnd, boolean valueFollows) {}

    /** The verdict. {@code secretSpans} are [start, end) ranges to hide. */
    public record Result(Category category, double confidence, Map<Category, Double> scores, List<String> reasons,
                         List<String> urls, List<String> emails, List<String> phones, Long dueAt,
                         List<int[]> secretSpans) {

        /** The text with every secret replaced by dots (keeping the last two characters as a hint). */
        public String redact(String text) {
            return redactSpans(text, secretSpans);
        }

        public Map<String, Object> toJson() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("category", category.name().toLowerCase(Locale.ROOT));
            m.put("confidence", Math.round(confidence * 100) / 100.0);
            Map<String, Object> s = new LinkedHashMap<>();
            scores.forEach((k, v) -> { if (v > 0) s.put(k.name().toLowerCase(Locale.ROOT), Math.round(v * 10) / 10.0); });
            m.put("scores", s);
            m.put("reasons", reasons);
            if (!urls.isEmpty()) m.put("urls", urls);
            if (!emails.isEmpty()) m.put("emails", emails);
            if (!phones.isEmpty()) m.put("phones", phones);
            if (dueAt != null) m.put("dueAt", dueAt);
            m.put("hasSecret", !secretSpans.isEmpty());
            return m;
        }
    }

    public static final int MAX_LENGTH = 20_000;
    static final double NOTE_BASELINE = 1.5;

    private static final AhoCorasick<Cue> CUES = buildCues();

    private static final List<String> SECRET_PREFIXES = List.of(
            "sk-", "sk_live_", "sk_test_", "pk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_",
            "glpat-", "xoxb-", "xoxp-", "xoxa-", "akia", "aiza", "ya29.", "eyj", "-----begin");

    /** Words after "password" that describe it rather than being it ("password manager"). */
    private static final Set<String> NOT_A_PASSWORD = Set.of("manager", "managers", "reset", "change", "changed",
            "changing", "policy", "expired", "expires", "expiry", "for", "to", "of", "the", "a", "an", "my", "your",
            "is", "was", "will", "has", "have", "had", "and", "or", "field", "hint", "strength", "protected",
            "protection", "rules", "requirements", "update", "updated", "recovery", "again", "please", "needs",
            "need", "here", "there", "it", "this", "that", "in", "on", "at", "with", "without", "less", "saved",
            "save", "stored", "generator", "length", "too", "list", "file", "screen", "prompt", "page", "box");

    /** Query-string keys whose values are credentials (…?access_token=…). */
    private static final List<String> SECRET_PARAMS = List.of("token", "key", "secret", "password", "passwd", "pass",
            "pwd", "auth", "sig", "signature", "session", "credential", "jwt");

    private static final Set<String> TLDS = Set.of("com", "org", "net", "io", "dev", "app", "in", "co", "ai", "me",
            "edu", "gov", "xyz", "so", "gg", "tv", "ly", "to", "sh", "uk", "us", "de", "info", "tech", "site", "page");

    private static AhoCorasick<Cue> buildCues() {
        AhoCorasick<Cue> ac = new AhoCorasick<>();
        // credentials: strong words, and weak ones that only matter together with a secret
        cue(ac, Category.CREDENTIAL, 3, true, "password", "passwd", "passcode", "secret", "api key", "apikey",
                "api_key", "access key", "private key", "recovery code", "backup code", "auth token", "bearer");
        cue(ac, Category.CREDENTIAL, 1, true, "pwd", "pass", "pin", "otp", "2fa", "token", "key");
        cue(ac, Category.CREDENTIAL, 1, false, "login", "username", "user id", "wifi", "wi-fi", "ssid");
        // reminders (a parsed time adds more, see below)
        cue(ac, Category.REMINDER, 3, false, "remind", "reminder", "don't forget", "dont forget", "remember to");
        cue(ac, Category.REMINDER, 1.5, false, "deadline", "due", "appointment", "alarm");
        cue(ac, Category.REMINDER, 1, false, "meeting", "tomorrow", "tonight", "today", "birthday");
        // to-dos
        cue(ac, Category.TODO, 3, false, "todo", "to-do", "to do");
        cue(ac, Category.TODO, 2, false, "buy", "need to", "have to", "fix", "finish", "pick up", "pay", "submit",
                "renew", "order", "book", "return", "schedule");
        cue(ac, Category.TODO, 1, false, "call", "send", "clean", "check", "get", "must", "should", "email");
        add(ac, "[ ]", Category.TODO, 3, false, false, false);
        add(ac, "- [ ]", Category.TODO, 1, false, false, false);
        // contacts
        cue(ac, Category.CONTACT, 1, false, "phone", "mobile", "mob", "tel", "contact", "number", "address",
                "whatsapp", "cell");
        // code: plain English-looking keywords count little on their own ("a letter from the bank")
        for (String w : new String[]{"function", "return", "class", "public", "static", "async", "await",
                "lambda", "import", "export", "const", "elif", "struct", "select", "from", "where"}) {
            add(ac, w, Category.CODE, 0.5, true, true, false);
        }
        for (String w : new String[]{"def ", "let ", "var ", "fn ", "func ", "sudo ", "npm ", "npx ", "yarn ",
                "brew ", "git ", "pip ", "cd ", "ls ", "curl ", "docker ", "kubectl ", "mvn ", "./"}) {
            add(ac, w, Category.CODE, 1.5, true, false, false);
        }
        for (String w : new String[]{"=>", "();", "{}", "!=", "==", "&&", "||", "#include", "console.log",
                "print(", "</", "/>", "->"}) {
            add(ac, w, Category.CODE, 1.5, false, false, false);
        }
        // ideas
        cue(ac, Category.IDEA, 3, false, "idea", "what if", "brainstorm");
        cue(ac, Category.IDEA, 2, false, "concept", "app that", "could build", "imagine", "maybe we", "pitch");
        return ac.build();
    }

    private static void cue(AhoCorasick<Cue> ac, Category c, double w, boolean valueFollows, String... words) {
        for (String word : words) add(ac, word, c, w, true, true, valueFollows);
    }

    private static void add(AhoCorasick<Cue> ac, String p, Category c, double w, boolean ws, boolean we, boolean vf) {
        ac.add(p, new Cue(c, w, ws, we, vf));
    }

    /** Classifies {@code text}. {@code now} and the UTC offset are used to resolve "tomorrow 5pm". */
    public Result classify(String text, long now, int utcOffsetMinutes) {
        if (text == null) throw new IllegalArgumentException("'text' is required");
        if (text.length() > MAX_LENGTH) throw new IllegalArgumentException("text longer than " + MAX_LENGTH + " characters");
        Map<Category, Double> score = new EnumMap<>(Category.class);
        for (Category c : Category.values()) score.put(c, 0.0);
        score.put(Category.NOTE, NOTE_BASELINE);
        List<String> reasons = new ArrayList<>();
        List<int[]> secrets = new ArrayList<>();

        // 1. Cue words, one pass. Each distinct word counts once.
        Set<String> seen = new HashSet<>();
        List<int[]> valueAfter = new ArrayList<>();   // {position after the cue, 1 if "password"-like}
        for (AhoCorasick.Match<Cue> m : CUES.findAll(text)) {
            Cue cue = m.payload();
            if (cue.wordStart() && m.start() > 0 && isWordChar(text.charAt(m.start() - 1))) continue;
            if (cue.wordEnd() && m.end() < text.length() && isWordChar(text.charAt(m.end()))) continue;
            if (cue.valueFollows()) {
                boolean passwordWord = Set.of("password", "passwd", "passcode", "pwd").contains(m.pattern());
                valueAfter.add(new int[]{m.end(), passwordWord ? 1 : 0});
            }
            if (!seen.add(cue.category() + ":" + m.pattern())) continue;
            score.merge(cue.category(), cue.weight(), Double::sum);
            if (cue.weight() >= 1.5 || (cue.category() != Category.CODE && cue.weight() >= 1)) {
                reasons.add("“" + m.pattern().strip() + "” → " + label(cue.category()));
            }
        }

        // 2. Structure, one scan over the tokens.
        List<int[]> tokens = tokens(text);
        List<int[]> urlSpans = new ArrayList<>(), emailSpans = new ArrayList<>();
        int plainWords = 0;
        for (int[] t : tokens) {
            String raw = text.substring(t[0], t[1]);
            String tok = stripPunctuation(raw);
            if (tok.isEmpty()) continue;
            int off = t[0] + raw.indexOf(tok);
            String low = tok.toLowerCase(Locale.ROOT);
            if (isUrl(low)) {
                urlSpans.add(new int[]{off, off + tok.length()});
                urlSecrets(tok, off, secrets);
                continue;
            }
            if (isEmail(tok)) { emailSpans.add(new int[]{off, off + tok.length()}); continue; }
            if (looksLikeSecret(tok, low)) {
                secrets.add(new int[]{off, off + tok.length()});
                continue;
            }
            plainWords++;
        }
        // A note that is nothing but one password-like token ("Tr0ub4dor&3").
        if (tokens.size() == 1) {
            String only = stripPunctuation(text.strip());
            int off = text.indexOf(only);
            String low = only.toLowerCase(Locale.ROOT);
            if (!only.isEmpty() && !isUrl(low) && !isEmail(only) && looksLikePassword(only)) {
                addSpan(secrets, off, off + only.length());
            }
        }
        List<int[]> phoneSpans = phones(text);

        // The value after "password:", "pin is", "api key = …", "password for netflix: …".
        for (int[] v : valueAfter) {
            int[] val = valueAfter(text, v[0], v[1] == 1);
            if (val != null) addSpan(secrets, val[0], val[1]);
        }
        // A private key block hides from its BEGIN line to its END line.
        String lowText = text.toLowerCase(Locale.ROOT);
        int begin = lowText.indexOf("-----begin");
        if (begin >= 0) {
            int end = lowText.indexOf("-----end", begin);
            int stop = end < 0 ? text.length() : text.indexOf("-----", end + 8);
            stop = stop < 0 ? text.length() : Math.min(text.length(), stop + 5);
            addSpan(secrets, begin, stop);
        }
        secrets = merge(secrets);

        // Nothing found inside a secret is reported or kept (no "phone: 1234 5678 9012" for a PIN).
        List<String> urls = outside(text, urlSpans, secrets);
        List<String> emails = outside(text, emailSpans, secrets);
        List<String> phones = outside(text, phoneSpans, secrets);

        if (!secrets.isEmpty()) {
            score.merge(Category.CREDENTIAL, 5.0, Double::sum);
            reasons.add("secret-looking value → hidden");
        } else {
            // "the secret to good coffee" mentions a credential word but holds no secret.
            score.put(Category.CREDENTIAL, score.get(Category.CREDENTIAL) * 0.4);
        }
        if (!urls.isEmpty()) {
            score.merge(Category.LINK, plainWords <= 4 ? 5.0 : 3.0, Double::sum);
            reasons.add("link: " + domainOf(urls.get(0)));
        } else if (!urlSpans.isEmpty()) {
            score.merge(Category.LINK, 2.0, Double::sum);   // a link that carries a secret
        }
        if (!emails.isEmpty() || !phones.isEmpty()) {
            score.merge(Category.CONTACT, 3.0 + 0.5 * (emails.size() + phones.size() - 1), Double::sum);
            reasons.add(!emails.isEmpty() ? "e-mail address" : "phone number");
        }
        Long due = parseDue(text, now, utcOffsetMinutes);
        if (due != null) {
            score.merge(Category.REMINDER, 3.0, Double::sum);
            reasons.add("time found → reminder");
        }
        double codeChars = 0;
        for (int i = 0; i < text.length(); i++) if ("{}();=<>[]$|&".indexOf(text.charAt(i)) >= 0) codeChars++;
        if (text.length() >= 12 && codeChars / text.length() >= 0.06) {
            score.merge(Category.CODE, 2.0, Double::sum);
            reasons.add("code punctuation");
        }
        if (text.strip().startsWith("$ ") || text.contains("\n    ") || text.contains("\n\t")) {
            score.merge(Category.CODE, 1.5, Double::sum);
        }

        Category best = Category.values()[0];
        double total = 0;
        for (Category c : Category.values()) {
            total += score.get(c);
            if (score.get(c) > score.get(best)) best = c;   // strict, in enum order: ties go to the earlier category
        }
        if (best != Category.CREDENTIAL && !secrets.isEmpty()) {
            // Never show a secret in the clear, whatever the note is mostly about.
            reasons.add("contains a secret");
        }
        return new Result(best, score.get(best) / total, score, reasons, urls, emails, phones, due, secrets);
    }

    /** Replaces each span with dots, keeping the last two characters of long secrets as a hint. */
    public static String redactSpans(String text, List<int[]> spans) {
        if (spans.isEmpty()) return text;
        StringBuilder b = new StringBuilder();
        int at = 0;
        for (int[] s : spans) {
            b.append(text, at, s[0]);
            String secret = text.substring(s[0], s[1]);
            b.append("••••••");
            if (secret.length() >= 10) b.append(secret, secret.length() - 2, secret.length());
            at = s[1];
        }
        b.append(text.substring(at));
        return b.toString();
    }

    // ---- structure helpers -------------------------------------------------------------------

    static boolean isWordChar(char c) { return Character.isLetterOrDigit(c) || c == '_'; }

    /** Whitespace-separated tokens as [start, end) pairs. */
    private static List<int[]> tokens(String s) {
        List<int[]> out = new ArrayList<>();
        int i = 0;
        while (i < s.length()) {
            while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++;
            int start = i;
            while (i < s.length() && !Character.isWhitespace(s.charAt(i))) i++;
            if (i > start) out.add(new int[]{start, i});
        }
        return out;
    }

    private static String stripPunctuation(String t) {
        int a = 0, b = t.length();
        while (a < b && "\"'“”‘’([{<,;:!?".indexOf(t.charAt(a)) >= 0) a++;
        while (b > a && "\"'“”‘’)]}>,.;:!?".indexOf(t.charAt(b - 1)) >= 0) b--;
        return t.substring(a, b);
    }

    /** The texts of {@code spans} that don't overlap any secret. */
    private static List<String> outside(String text, List<int[]> spans, List<int[]> secrets) {
        List<String> out = new ArrayList<>();
        for (int[] s : spans) {
            boolean overlaps = false;
            for (int[] x : secrets) if (s[0] < x[1] && x[0] < s[1]) { overlaps = true; break; }
            if (!overlaps) out.add(text.substring(s[0], s[1]).strip());
        }
        return out;
    }

    static boolean isUrl(String low) {
        if (low.startsWith("http://") || low.startsWith("https://")) return low.length() > 8;
        if (low.startsWith("www.") && low.length() > 6) return true;
        if (low.contains("@") || low.contains(" ")) return false;
        int slash = low.indexOf('/');
        String host = slash < 0 ? low : low.substring(0, slash);
        int dot = host.lastIndexOf('.');
        if (dot <= 0 || dot == host.length() - 1) return false;
        String tld = host.substring(dot + 1);
        if (!TLDS.contains(tld)) return false;
        for (int i = 0; i < host.length(); i++) {
            char c = host.charAt(i);
            if (!(Character.isLetterOrDigit(c) || c == '.' || c == '-')) return false;
        }
        return true;
    }

    /** Secrets inside a URL: the password in user:pass@host, and credential-looking query values. */
    private static void urlSecrets(String url, int off, List<int[]> secrets) {
        int scheme = url.indexOf("://");
        int hostStart = scheme < 0 ? 0 : scheme + 3;
        int slash = url.indexOf('/', hostStart);
        int at = url.indexOf('@', hostStart);
        if (at > 0 && (slash < 0 || at < slash)) {
            int colon = url.indexOf(':', hostStart);
            if (colon > 0 && colon < at) addSpan(secrets, off + colon + 1, off + at);
        }
        int q = url.indexOf('?');
        int hash = url.indexOf('#');
        int params = q >= 0 ? q : hash;
        if (params < 0) return;
        int i = params + 1;
        while (i < url.length()) {
            int amp = i;
            while (amp < url.length() && url.charAt(amp) != '&' && url.charAt(amp) != '#') amp++;
            int eq = url.indexOf('=', i);
            if (eq > i && eq < amp) {
                String key = url.substring(i, eq).toLowerCase(Locale.ROOT);
                String value = url.substring(eq + 1, amp);
                boolean namedSecret = false;
                for (String p : SECRET_PARAMS) if (key.contains(p)) { namedSecret = true; break; }
                if (value.length() >= 4 && (namedSecret || looksLikeSecret(value, value.toLowerCase(Locale.ROOT)))) {
                    addSpan(secrets, off + eq + 1, off + amp);
                }
            }
            i = amp + 1;
        }
    }

    static boolean isEmail(String t) {
        int at = t.indexOf('@');
        if (at <= 0 || at != t.lastIndexOf('@') || at == t.length() - 1) return false;
        String domain = t.substring(at + 1);
        int dot = domain.lastIndexOf('.');
        if (dot <= 0 || dot >= domain.length() - 2) return false;
        for (int i = 0; i < t.length(); i++) {
            char c = t.charAt(i);
            if (!(Character.isLetterOrDigit(c) || "._%+-@".indexOf(c) >= 0)) return false;
        }
        return true;
    }

    static boolean looksLikeSecret(String tok, String low) {
        for (String p : SECRET_PREFIXES) {
            if (!low.startsWith(p) || tok.length() < p.length() + 8) continue;
            // Real keys carry digits ("sk-proj-4fQ…"); "sk-learn-tutorial" doesn't.
            String rest = tok.substring(p.length());
            if (rest.chars().anyMatch(Character::isDigit) || rest.length() >= 20) return true;
        }
        if (tok.length() < 16 || tok.length() > 512) return false;
        // Paths, UUIDs and commit hashes are high-entropy but not secrets on their own.
        if (low.startsWith("/") || low.startsWith("~/") || low.startsWith("./")) return false;
        if (low.chars().allMatch(c -> Character.digit(c, 16) >= 0 || c == '-')) return false;
        // File names ("report_final2.pdf") end in an extension; keys don't.
        int dot = low.lastIndexOf('.');
        if (dot > 0 && low.length() - dot - 1 >= 2 && low.length() - dot - 1 <= 4
                && low.substring(dot + 1).chars().allMatch(Character::isLetter)) return false;
        boolean lower = false, upper = false, digit = false;
        for (int i = 0; i < tok.length(); i++) {
            char c = tok.charAt(i);
            if (Character.isLowerCase(c)) lower = true;
            else if (Character.isUpperCase(c)) upper = true;
            else if (Character.isDigit(c)) digit = true;
        }
        // Random keys are mixed case (base62/64), or long.
        return (lower || upper) && digit && (lower && upper || tok.length() >= 24) && entropy(tok) >= 3.5;
    }

    /**
     * A password-shaped token on its own: 8–64 characters, no spaces, upper and lower case plus
     * a digit or symbol, and not a path.
     */
    static boolean looksLikePassword(String t) {
        if (t.length() < 8 || t.length() > 64) return false;
        if (t.startsWith("/") || t.startsWith("~/") || t.startsWith("./") || t.startsWith("#")) return false;
        boolean lower = false, upper = false, digit = false, symbol = false;
        for (int i = 0; i < t.length(); i++) {
            char c = t.charAt(i);
            if (Character.isWhitespace(c)) return false;
            if (Character.isLowerCase(c)) lower = true;
            else if (Character.isUpperCase(c)) upper = true;
            else if (Character.isDigit(c)) digit = true;
            else symbol = true;
        }
        // Mixed case plus a digit or symbol: "Tr0ub4dor&3" yes; "report_final2.pdf", UUIDs and
        // version strings no.
        return lower && upper && (digit || symbol);
    }

    /** Shannon entropy in bits per character. Random keys score ~4–6; words and paths ~2.5–3.5. */
    static double entropy(String s) {
        Map<Character, Integer> counts = new java.util.HashMap<>();
        for (int i = 0; i < s.length(); i++) counts.merge(s.charAt(i), 1, Integer::sum);
        double h = 0;
        for (int n : counts.values()) {
            double p = (double) n / s.length();
            h -= p * Math.log(p) / Math.log(2);
        }
        return h;
    }

    private static boolean hasDigitOrSymbol(String s) {
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (Character.isDigit(c) || (!Character.isLetter(c) && !Character.isWhitespace(c))) return true;
        }
        return false;
    }

    /**
     * The secret value after a credential word, as [start, end), or null.
     * <ul>
     *   <li>A ":" or "=" within the next 40 characters of the line ("password for netflix: x"),
     *       or "-" after the word, or "is"/"are" after "password", introduce the value:
     *       everything up to the end of the line is hidden, so passphrases ("correct horse
     *       battery staple") are hidden whole.</li>
     *   <li>Otherwise only the next word: after "password" it's hidden unless it describes the
     *       password ("password manager"); after a weaker word ("pin", "token") only if it has a
     *       digit or symbol ("pin 4821").</li>
     * </ul>
     */
    private static int[] valueAfter(String s, int from, boolean passwordWord) {
        int lineEnd = s.indexOf('\n', from);
        if (lineEnd < 0) lineEnd = s.length();
        int limit = Math.min(lineEnd, from + 40);
        int sep = -1;
        for (int i = from; i < limit; i++) {
            char c = s.charAt(i);
            if (c == ':' || c == '=') { sep = i; break; }
            if (c == '.' || c == '?' || c == '!') break;      // a new sentence
        }
        int start;
        boolean explicit;
        if (sep >= 0) {
            start = sep + 1;
            explicit = true;
        } else {
            start = from;
            explicit = false;
            int i = skipSpaces(s, from, lineEnd);
            if (i < lineEnd && s.charAt(i) == '-') {
                start = i + 1;
                explicit = true;
            } else {
                int end = wordEnd(s, i, lineEnd);
                String w = s.substring(i, end).toLowerCase(Locale.ROOT);
                if (w.equals("is") || w.equals("are")) {
                    // "password is …" introduces the whole value; "pin is 4821" just the next word.
                    start = end;
                    explicit = passwordWord;
                }
            }
        }
        start = skipSpaces(s, start, lineEnd);
        if (start >= lineEnd) return null;
        if (explicit) {
            int end = lineEnd;
            while (end > start && (Character.isWhitespace(s.charAt(end - 1)) || ".,;!?\"'”’)".indexOf(s.charAt(end - 1)) >= 0)) end--;
            while (start < end && "\"'“‘(".indexOf(s.charAt(start)) >= 0) start++;
            if (end - start < 3) return null;
            String val = s.substring(start, end);
            String low = val.toLowerCase(Locale.ROOT);
            if (isUrl(low) && !low.contains("@") && !low.contains("?")) return null;    // "password reset: https://…"
            if (isEmail(val)) return null;
            if (passwordWord && NOT_A_PASSWORD.contains(low.split("\\s+")[0]) && !hasDigitOrSymbol(val)
                    && s.charAt(start - 1) != ':' && sep < 0) {
                return null;                                                            // "password is too short"
            }
            return new int[]{start, end};
        }
        int end = wordEnd(s, start, lineEnd);
        String val = stripPunctuation(s.substring(start, end));
        if (val.isEmpty()) return null;
        int vs = start + s.substring(start, end).indexOf(val);
        String low = val.toLowerCase(Locale.ROOT);
        if (isUrl(low) || isEmail(val)) return null;
        if (passwordWord) {
            if (val.length() < 3 || NOT_A_PASSWORD.contains(low)) return null;
        } else if (!(hasDigitOrSymbol(val) && val.length() >= 4)) {
            return null;
        }
        return new int[]{vs, vs + val.length()};
    }

    private static int skipSpaces(String s, int i, int end) {
        while (i < end && (s.charAt(i) == ' ' || s.charAt(i) == '\t')) i++;
        return i;
    }

    private static int wordEnd(String s, int i, int end) {
        while (i < end && !Character.isWhitespace(s.charAt(i))) i++;
        return i;
    }

    private static void addSpan(List<int[]> spans, int a, int b) {
        if (b > a) spans.add(new int[]{a, b});
    }

    private static List<int[]> merge(List<int[]> spans) {
        spans.sort((x, y) -> Integer.compare(x[0], y[0]));
        List<int[]> out = new ArrayList<>();
        for (int[] s : spans) {
            if (!out.isEmpty() && s[0] <= out.get(out.size() - 1)[1]) {
                out.get(out.size() - 1)[1] = Math.max(out.get(out.size() - 1)[1], s[1]);
            } else {
                out.add(new int[]{s[0], s[1]});
            }
        }
        return out;
    }

    /** Runs of digits, spaces, '+', '-', '(', ')' holding 10–15 digits, as [start, end) spans. */
    static List<int[]> phones(String s) {
        List<int[]> out = new ArrayList<>();
        int i = 0;
        while (i < s.length()) {
            char c = s.charAt(i);
            // A phone number starts a token: "+91 98765 43210", "(555) 123-4567"; not the tail
            // of a longer token like a UUID or a version string.
            boolean starts = (Character.isDigit(c) || c == '+' || c == '(')
                    && (i == 0 || Character.isWhitespace(s.charAt(i - 1)) || "(:,;".indexOf(s.charAt(i - 1)) >= 0);
            if (!starts) { i++; continue; }
            int j = i, digits = 0, lastDigit = i;
            while (j < s.length() && "0123456789 +-()".indexOf(s.charAt(j)) >= 0) {
                if (Character.isDigit(s.charAt(j))) { digits++; lastDigit = j; }
                j++;
            }
            boolean endsClean = lastDigit + 1 >= s.length() || Character.isWhitespace(s.charAt(lastDigit + 1))
                    || ",.;)".indexOf(s.charAt(lastDigit + 1)) >= 0;
            if (digits >= 10 && digits <= 15 && endsClean) out.add(new int[]{i, lastDigit + 1});
            i = Math.max(j, i + 1);
        }
        return out;
    }

    static String domainOf(String url) {
        String u = url.toLowerCase(Locale.ROOT).replaceFirst("^https?://", "").replaceFirst("^www\\.", "");
        int at = u.indexOf('@');
        int slash = u.indexOf('/');
        if (at >= 0 && (slash < 0 || at < slash)) u = u.substring(at + 1);   // never show user:pass@
        slash = u.indexOf('/');
        String host = slash < 0 ? u : u.substring(0, slash);
        int q = host.indexOf('?');
        return q < 0 ? host : host.substring(0, q);
    }

    private static String label(Category c) {
        return switch (c) {
            case CREDENTIAL -> "password/key";
            case REMINDER -> "reminder";
            case LINK -> "link";
            case CONTACT -> "contact";
            case TODO -> "to-do";
            case CODE -> "code";
            case IDEA -> "idea";
            case NOTE -> "note";
        };
    }

    // ---- due time --------------------------------------------------------------------------

    private static final Map<String, DayOfWeek> WEEKDAYS = new LinkedHashMap<>();
    static {
        String[][] names = {{"monday", "mon"}, {"tuesday", "tue", "tues"}, {"wednesday", "wed"},
                {"thursday", "thu", "thur", "thurs"}, {"friday", "fri"}, {"saturday", "sat"}, {"sunday", "sun"}};
        for (int d = 0; d < 7; d++) for (String n : names[d]) WEEKDAYS.put(n, DayOfWeek.of(d + 1));
    }

    /**
     * Finds a due time: "in 20 min", "in 2 hours", "tomorrow", "tonight", "friday 9am",
     * "at 5pm", "5:30 pm", "at 5:30", "17:00", "next week", "morning/afternoon/evening/noon".
     * <ul>
     *   <li>A clock time with no day that has already passed means tomorrow.</li>
     *   <li>"at 5" and "1:30" with no am/pm mean the afternoon for hours 1–7.</li>
     *   <li>A weekday means its next occurrence; today's name counts if the time is still ahead.</li>
     *   <li>"today"/"tonight" with no time, said after the default hour, means an hour from now.</li>
     * </ul>
     * Returns epoch millis, or null.
     */
    static Long parseDue(String text, long now, int utcOffsetMinutes) {
        ZoneOffset zone = ZoneOffset.ofTotalSeconds(Math.max(-18 * 3600, Math.min(18 * 3600, utcOffsetMinutes * 60)));
        LocalDateTime local = LocalDateTime.ofInstant(Instant.ofEpochMilli(now), zone);
        LocalDate today = local.toLocalDate();
        String[] w = text.toLowerCase(Locale.ROOT).replaceAll("[,;!?()\"]", " ").split("\\s+");

        LocalDate day = null;
        DayOfWeek weekday = null;
        LocalTime time = null, softTime = null;   // softTime: implied by "tonight", "morning"…
        long relativeMinutes = -1;
        for (int i = 0; i < w.length; i++) {
            String t = w[i].replaceAll("\\.$", "");
            String nextWord = i + 1 < w.length ? w[i + 1].replaceAll("\\.$", "") : "";
            String prev = i > 0 ? w[i - 1] : "";
            switch (t) {
                case "tomorrow", "tmrw", "tmr", "tomorow" -> day = today.plusDays(1);
                case "today" -> day = today;
                case "tonight" -> { day = today; softTime = LocalTime.of(20, 0); }
                case "morning" -> softTime = LocalTime.of(9, 0);
                case "afternoon" -> softTime = LocalTime.of(15, 0);
                case "evening" -> softTime = LocalTime.of(19, 0);
                case "noon" -> time = LocalTime.NOON;
                case "next" -> { if (nextWord.equals("week")) day = today.plusWeeks(1); }
                case "in" -> {
                    long mins = relative(w, i + 1);
                    if (mins > 0) relativeMinutes = mins;
                }
                default -> {
                    if (WEEKDAYS.containsKey(t) && (t.length() > 3 || prev.equals("on") || prev.equals("by"))) {
                        weekday = WEEKDAYS.get(t);
                    } else {
                        LocalTime parsed = parseTime(t, nextWord, prev);
                        if (parsed != null) time = parsed;
                    }
                }
            }
        }
        if (relativeMinutes > 0) {
            return local.plusMinutes(relativeMinutes).toInstant(zone).toEpochMilli();
        }
        if (day == null && weekday == null && time == null && softTime == null) return null;

        LocalTime at = time != null ? time : softTime != null ? softTime : LocalTime.of(9, 0);
        LocalDateTime due;
        if (weekday != null) {
            due = today.with(TemporalAdjusters.nextOrSame(weekday)).atTime(at);
            if (!due.isAfter(local)) due = due.plusWeeks(1);          // today's name, but the time has gone
        } else if (day != null) {
            due = day.atTime(at);
            if (time == null && !due.isAfter(local)) {
                // "finish the report today" at 3 pm, "tonight" at 9 pm: soon, not in the past.
                due = local.plusHours(1).withSecond(0).withNano(0);
            }
        } else {
            due = today.atTime(at);
            if (!due.isAfter(local)) due = due.plusDays(1);
        }
        return due.toInstant(zone).toEpochMilli();
    }

    /** "20 min", "2 hours", "an hour", "half an hour", "3 days" starting at w[i] → minutes. */
    private static long relative(String[] w, int i) {
        if (i >= w.length) return -1;
        if (w[i].equals("half") && i + 2 < w.length && w[i + 2].startsWith("hour")) return 30;
        long n;
        String unit;
        String first = w[i];
        int digits = 0;
        while (digits < first.length() && Character.isDigit(first.charAt(digits))) digits++;
        if (first.equals("an") || first.equals("a")) {
            n = 1;
            unit = i + 1 < w.length ? w[i + 1] : "";
        } else if (digits > 0 && digits <= 4) {
            n = Long.parseLong(first.substring(0, digits));
            unit = digits < first.length() ? first.substring(digits) : (i + 1 < w.length ? w[i + 1] : "");
        } else {
            return -1;
        }
        unit = unit.replaceAll("\\.$", "");
        if (unit.matches("m|min|mins|minute|minutes")) return n;
        if (unit.matches("h|hr|hrs|hour|hours")) return n * 60;
        if (unit.matches("d|day|days")) return n * 24 * 60;
        if (unit.matches("week|weeks")) return n * 7 * 24 * 60;
        return -1;
    }

    /**
     * "5pm", "5:30pm", "5.30pm", "17:00", "5 pm" (next = "pm"), "at 5" / "at 5:30" (prev = "at").
     * A dot only counts with am/pm or after "at"/"by", so "2.49" and "python 3.12" aren't times.
     */
    private static LocalTime parseTime(String t, String next, String prev) {
        String s = t.startsWith("@") ? t.substring(1) : t;
        String suffix = "";
        if (s.endsWith("am") || s.endsWith("pm")) {
            suffix = s.substring(s.length() - 2);
            s = s.substring(0, s.length() - 2);
        } else if (next.equals("am") || next.equals("pm") || next.equals("a.m") || next.equals("p.m")) {
            suffix = next.substring(0, 1) + "m";
        }
        if (s.isEmpty()) return null;
        boolean anchored = prev.equals("at") || prev.equals("by") || prev.equals("@");
        int colon = s.indexOf(':'), dot = s.indexOf('.');
        if (dot >= 0 && suffix.isEmpty() && !anchored) return null;
        int sep = colon >= 0 ? colon : dot;
        int hour, minute = 0;
        try {
            if (sep > 0) {
                if (s.length() - sep - 1 != 2) return null;
                hour = Integer.parseInt(s.substring(0, sep));
                minute = Integer.parseInt(s.substring(sep + 1));
            } else {
                if (s.length() > 2) return null;
                hour = Integer.parseInt(s);
            }
        } catch (NumberFormatException e) {
            return null;
        }
        if (suffix.isEmpty() && sep < 0 && !anchored) return null;   // "5 apples"
        if (minute < 0 || minute > 59) return null;
        if (suffix.equals("pm")) {
            if (hour < 1 || hour > 12) return null;
            if (hour != 12) hour += 12;
        } else if (suffix.equals("am")) {
            if (hour < 1 || hour > 12) return null;
            if (hour == 12) hour = 0;
        } else if (hour >= 1 && hour <= 7 && s.charAt(0) != '0') {
            hour += 12;                    // "at 5", "at 5:30", "lunch 1:30": almost always the afternoon
        }
        if (hour < 0 || hour > 23) return null;
        return LocalTime.of(hour, minute);
    }
}
