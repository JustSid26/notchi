# Notchi backend (Java)

The Notchi Mac app is the front end. This Java service runs next to it on the same Mac and does the algorithmic work:

| Island feature | Problem | Algorithm (own implementation) | Syllabus |
|---|---|---|---|
| **LIVE queue** | Many activities change state all the time. The island must always show the most urgent first, and drop finished ones on time. | **Indexed binary heap** (urgency), plus a second one keyed by expiry time | Unit 2 · CO2 |
| **Duplicate screening** | Retried webhooks, hooks registered twice and replayed `island push` calls must not re-order the queue or roll a finished job back to "running". | **Bloom filter** in front of an exact event log; a "possibly seen" answer is always confirmed | Unit 6 · CO5 |
| **Launcher** | Typing in the Claude bar finds apps, pinned terminal tabs and commands instantly, ranked by how often you open them. | **Trie** (prefix tree) with word-start indexing and top-k selection | Unit 4 · CO3 |
| **Claude ETA** | While Claude works in a tab, show how long it usually takes ("1:12 / ~2:14"). | **Randomized Quickselect** (Las Vegas) for p50 / p90 / p99 | Unit 6 · CO5 |
| **Smart Notes** | Type anything; it's filed as a reminder (with a due time that pings you), to-do, link, password/key (hidden, kept in the Keychain), contact, code, idea or note. | **Aho–Corasick** (a trie with KMP failure links) finds every cue word in one pass; **KMP** is the baseline | Unit 4 · CO3 |
| **Clipboard history** | Everything you copied, searchable anywhere inside the text. Passwords are never kept. | **Suffix array** built by prefix doubling with **radix (counting) sort** | Units 4 + 1 · CO3 |
| **Screen time** | Today's total, time per app, hourly bars, busiest hour, longest focus. | **Segment tree** (range sum / range max / argmax) per app per day | Unit 3 · CO2 |
| **Workspaces** | Apps you keep using together become one-click groups. | **Union–find** (union by rank + path compression) | Unit 2 · CO2 |

The backend is plain Java 21 with no runtime dependencies: the HTTP server is the JDK's `com.sun.net.httpserver`, and the JSON parser is in `json/Json.java`. JUnit 5 is used for tests only.

`scripts/build-app.sh` bundles the jar inside Notchi.app, and Notchi starts it by itself when Java 21+ is installed. The log goes to `~/Library/Logs/Notchi-backend.log`. Without Java, Notchi still works; the Notes, Clipboard and Activity pages just say the backend is needed.

```
backend/
  src/main/java/dev/notchi/backend/
    algo/heap/IndexedBinaryHeap.java   algo/trie/Trie.java
    algo/bloom/BloomFilter.java        algo/select/RandomizedSelect.java (+ SelectBaselines)
    algo/text/AhoCorasick.java, Kmp.java, SuffixIndex.java
    algo/tree/SegmentTree.java         algo/dsu/DisjointSet.java
    live/   LiveQueue, EventDeduplicator, LiveActivity     ← services that use the algorithms
    notes/  NoteClassifier, NotesStore    clipboard/ClipboardHistory
    activity/ScreenTime, Workspaces, DemoActivity
    launcher/Launcher.java   stats/DurationStats.java
    http/   ApiServer (routing, errors), NotchiApi (endpoints + validation)
    bench/  BenchmarkRunner, SampleDataGenerator
    json/   Json
  src/test/java/…                      110 JUnit tests
  src/main/resources/sample/durations.csv   synthetic sample data (900 Claude runs)
  docs/ALGORITHMS.md                   pseudocode, correctness, complexity, edge cases
  docs/benchmarks.md / .csv            measured results vs baselines
  scripts/demo-events.sh               live-demo event burst with retries
```

## Run it

You need JDK 21 or newer. The bundled Maven wrapper (`./mvnw`) downloads Maven on first use.

```bash
cd backend
./mvnw test                                   # 110 tests
./mvnw -q package -DskipTests                 # → target/notchi-backend.jar
java -jar target/notchi-backend.jar --demo    # in-memory, with sample durations, a week of screen time and 6 notes
java -jar target/notchi-backend.jar           # keeps history in ~/Library/Application Support/Notchi/backend
```

Options: `--port 7340` (the app expects 7340), `--data DIR`, `--demo`. The server only listens on 127.0.0.1.

When Notchi starts the backend, it sets `NOTCHI_TOKEN` to a random key kept in your Keychain. Every request except `/api/health` must then carry `X-Notchi-Token`, so other programs can't read your notes or clipboard. A backend you start by hand has no token, so the `curl` examples below work against it.

Then start Notchi (`../scripts/build-app.sh && open ../build/Notchi.app`). Within 5 seconds it connects, and **Settings → Java backend** shows "Connected" with live numbers from each algorithm. In the island:

- The LIVE card gets a **HEAP** tag, and its order comes from the backend.
- Typing in the Claude bar replaces the pinned apps with **launcher results** ("Trie · 0.19 ms · 137 items"). Press ⌘1… to open one; Return still asks Claude.
- A terminal tab where Claude is working shows **elapsed / usual time**. Hover it for p50 and p90.
- The page switcher at the bottom-left (in the header when the island is on the left edge) opens:
  - **Notes:** write anything, and a live chip shows where it will be filed.
  - **Clipboard:** click a clip to copy it again; search inside everything you've copied.
  - **Activity:** screen time and workspaces.

  You can also jump to a page with `open "notchi://page?to=notes"`.

### Benchmarks and sample data

```bash
java -cp target/notchi-backend.jar dev.notchi.backend.bench.BenchmarkRunner docs        # ~1 min → docs/benchmarks.md
java -cp target/notchi-backend.jar dev.notchi.backend.bench.SampleDataGenerator src/main/resources/sample/durations.csv
./scripts/demo-events.sh 40 0.3                                                          # 40 events, 30% retried
```

The sample durations are synthetic. Each of five tabs draws its run times from a log-normal distribution (most runs short, a few very long), with fixed seeds, so the file is reproducible. You can also import your own history: **Settings → Java backend → Import Claude run times…**, or `POST /api/durations/import` with `key,seconds` lines. History is kept per tab: under its custom name if you gave it one (`island tab add "CRM"` → key `crm`), otherwise under the tab's id. A tab with fewer than 5 runs uses all tabs together.

## API

All bodies are JSON unless noted. Errors look like `{"status":400,"error":"'progress' must be between 0 and 1"}` (400 bad input, 401 missing token, 403 request from a web page, 404, 405, 409 queue full, 413 body over 2 MB). Requests that carry an `Origin` header, or a `Host` other than 127.0.0.1/localhost, are refused, so web pages can't write to the backend.

| Method & path | What it does |
|---|---|
| `GET /api/health` | status, version, algorithm list |
| `GET /api/stats` | live numbers from every algorithm (heap size, Bloom bits/k/fill/FPR, trie nodes, runs) |
| `POST /api/live/events?limit=20` | push an event: `{id, state, title?, subtitle?, progress?, icon?, tint?, ttl?, eventId?}` → verdict, new order and queue `version` |
| `GET /api/live?limit=20` | the most urgent activities, in heap order, with the queue `version` |
| `DELETE /api/live/{id}` | remove an activity |
| `PUT /api/live/dedupe` | resize the Bloom filter: `{expected, fpp}` |
| `PUT /api/launcher/catalog` | replace the launcher catalog: `{items:[{id,label,kind:app\|tab\|command,path?}]}`; items that can't be indexed (e.g. an emoji-only name) are skipped and listed |
| `GET /api/launcher/search?q=fi&k=6` | prefix search, most-launched first |
| `POST /api/launcher/use` | count a launch: `{id}` |
| `POST /api/durations` | record a finished Claude run: `{key, seconds}` → updated percentiles |
| `POST /api/durations/import` | CSV body: `key,seconds` per line (header optional) |
| `GET /api/durations/summary?key=crm` | p50 / p90 / p99 / min / max for a tab (falls back to all tabs under 5 runs) |
| `POST /api/notes/classify` | `{text, tz}` → category, confidence, reasons, urls/emails/phones, `dueAt`, `hasSecret` (nothing stored) |
| `POST /api/notes` | `{text, tz}` → the stored note (secrets redacted) plus `secretSpans` for the app's Keychain |
| `GET /api/notes?category=&q=` | notes, pinned first then newest; `q` matches anywhere (suffix array); plus counts per category |
| `PATCH /api/notes/{id}` | `{done?, fired?, pinned?, category?}` |
| `GET /api/notes/due` · `DELETE /api/notes/{id}` | reminders whose time has come · delete |
| `POST /api/clipboard` | `{text, source?}` → `added`, `merged` (copied before) or `skipped-secret` |
| `GET /api/clipboard?q=` · `PATCH`/`DELETE /api/clipboard/{id}` · `DELETE /api/clipboard` | list or search · pin/delete one · clear (pinned stay) |
| `POST /api/activity/spans` | `{tz, spans:[{app, name, start, end}]}`: which app was in front, in epoch ms |
| `GET /api/activity/today?tz=` · `GET /api/activity/range?app=&from=&to=` | totals, per app, hourly, busiest hour, longest focus · seconds in a range |
| `GET /api/workspaces?tz=` · `POST /api/workspaces/dismiss` | suggested app groups · hide one (`{apps:[…]}`) |
| `POST /api/lab/select` | your own numbers: `{values:[…], percentiles:[50,90]}` → Quickselect vs sort, checked |
| `POST /api/lab/bloom` | your own keys: `{expected, fpp, inserts:[…], queries:[…]}` → per-key answers + observed FPR |

```bash
curl -s -X POST localhost:7340/api/live/events -d '{"id":"deploy","title":"Deploying web","state":"running","progress":0.4,"eventId":"gh-run-981"}'
# {"accepted":true,"verdict":"new","size":1,"version":1,"order":["deploy"]}
curl -s -X POST localhost:7340/api/live/events -d '{"id":"deploy","title":"Deploying web","state":"running","progress":0.4,"eventId":"gh-run-981"}'
# {"accepted":false,"verdict":"duplicate","size":1,"version":1,"order":["deploy"]}
curl -s 'localhost:7340/api/durations/summary?key=crm'
# {"key":"crm","scope":"crm","count":240,"algorithm":"Randomized Quickselect","enough":true,"p50":143.8,"p90":302.6,…}
curl -s 'localhost:7340/api/launcher/search?q=sa&k=4'
# {"query":"sa","algorithm":"Trie (prefix tree), top-k by launches","tookMicros":24.1,"catalogSize":137,"items":[{"id":"app:/Applications/Safari.app","label":"Safari",…}]}
```

From the Mac app's own CLI, `island push --id deploy --state done --event gh-run-982` goes through the same path.

## Results in short

From `docs/benchmarks.md` (Apple Silicon, Java 24):

- **LIVE heap:** 100 rounds of "update one activity + read the top 10" over 100,000 activities take 0.16 ms in total, against 1.86 s when re-sorting on every read (≈12,000×).
- **Trie:** 45 µs vs 2.8 ms per 4-letter query on 100,000 items (63×). A 1-letter prefix still gives 6×.
- **Bloom filter:** 1.1 MB vs ~63 MB for an exact set of 1M ids, with 1.01% observed false positives (target 1%).
- **Quickselect:** 8 ms vs 50 ms to sort 1M values. On sorted input, a fixed first-element pivot needs 384M comparisons for n = 32,000; the random pivot needs 124k.
- **Aho–Corasick:** 0.2 ms to find 10,000 cue words in a 10,000-character note, against 142 ms for KMP run once per word (687×).
- **Suffix array:** 8.6 µs vs 693 µs per query over 5,000 clips (81×); the index builds in 16 ms.
- **Segment tree:** 20,000 updates and range queries over a million minutes in 3.3 ms; a plain array takes 806 ms, and prefix sums about 3.2 s.
- **Union–find:** 1.5 ms vs 1.15 s for BFS recomputation with 100,000 apps and 1,000 questions (766×).

See [docs/ALGORITHMS.md](docs/ALGORITHMS.md) for pseudocode, correctness arguments, complexity, assumptions and failure cases.

## Limitations

- One user, one Mac: the server binds to 127.0.0.1 and has no authentication.
- The LIVE queue and the event log live in memory. After a backend restart the app re-sends what's on screen, so the queue comes back, but the event-id history doesn't: a retry that arrives after a restart is accepted as new. Durations and launch counts are saved to disk.
- Duplicate detection covers 24 hours while the backend runs. An id that comes back later is treated as new.
- Events without an `eventId` are fingerprinted by content in 2-second windows, and only an event identical to the activity's current content can be dropped. So a quick change back (running → attention → running) always goes through. Identical updates more than 2 s apart, or straddling a window edge, both count. Only senders that supply an `eventId` are protected against late, out-of-order replays.
- ETA percentiles describe past runs. A task unlike earlier ones will not follow them.
- Note sorting is rule-based (cue words + structure), not machine learning. Ambiguous notes can land in the wrong place; right-click a note → **Move to** fixes it.
- Secrets are found by rules. "password: …", "password is …", known key formats, long random tokens and mixed-case password-shaped notes are hidden. A password written with no cue at all inside a longer sentence can be missed; write "password: …" to be sure. Filing a note under Passwords by hand hides all of it.
- Due times understand "in 20 min", "tomorrow 5pm", "friday 9:30am", "tonight", "next week" and similar, but not calendar dates like "on 3 December".
- Screen time records only which app is in front (bundle id and name). It stops after 2 minutes without input (that idle time is removed) or when the screen locks, and keeps 35 days. Workspaces need a few days of use before they appear.
- On the night the clocks go back for daylight saving, the repeated hour is counted once.
- Clipboard history keeps text only (no images or files), the last 500 clips, and skips anything a password manager marks as concealed or that looks like a password or key.
