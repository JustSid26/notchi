# Algorithms

Each section covers:

- where the algorithm is used in Notchi
- what goes in and comes out
- the assumptions and limits we enforce
- pseudocode
- why it's correct
- cost
- how failures are handled
- which tests check it

Measured numbers are in [benchmarks.md](benchmarks.md). Sections 1–4 serve the LIVE queue, launcher and Claude ETA. Sections 5–8 serve Notes, Clipboard history, Screen time and Workspaces.

---

## 1. Indexed binary heap: the LIVE queue (Unit 2 · CO2)

**Code:** `algo/heap/IndexedBinaryHeap.java`, used by `live/LiveQueue.java`.

**Problem.** The island's LIVE card lists builds, deploys, Claude runs, timers and anything pushed with `island push`. Activities are updated constantly. The card must show the most urgent first:

1. needs your approval
2. running
3. failed
4. done

Within the same state, the newest comes first. Finished activities must disappear after their time-to-live.

**Inputs.** Events `{id, state, title, progress?, ttl, eventId?}`. Limits:
- state ∈ {running, attention, failed, done}
- progress ∈ [0, 1]
- ttl ∈ [0, 7 days], where 0 means "until ended"
- id ≤ 200 characters, title ≤ 200 characters
- at most 10,000 activities

**Output.** The k most urgent activities, in order.

**Data structure.** An array-backed binary max-heap plus a hash map `key → array index`. The map makes `update(key)` and `remove(key)` O(log n) instead of O(n). A second indexed heap is keyed by expiry time (soonest first) and acts as a timer queue.

**Priority.** `compare(a, b)` compares:
1. state rank (attention 3 > running 2 > failed 1 > done 0)
2. then the update time (newer is more urgent)
3. then the id (so ties are deterministic)

```
push(key, v):    append (key, v); pos[key] = n-1; siftUp(n-1)
update(key, v):  i = pos[key]; old = val[i]; val[i] = v
                 if v more urgent than old: siftUp(i) else siftDown(i)
remove(key):     i = pos[key]; swap(i, last); delete last; siftUp(i); siftDown(i)
siftUp(i):       while i > 0 and val[i] > val[parent(i)]: swap(i, parent(i)); i = parent(i)
siftDown(i):     while a child is larger: swap with the larger child
topK(k):         frontier = heap of indices {0}
                 repeat k times: i = frontier.popMax(); output i; push children 2i+1, 2i+2
expire(now):     while expiryHeap.peek().time <= now: id = expiryHeap.poll(); urgency.remove(id)
```

**Correctness.**
- *Heap order:* every parent is at least as urgent as its children.
- *Index map:* `pos[keys[i]] == i` for every i.

`swap` keeps the index map in step with the arrays. A sift moves an element along one root-to-leaf path and stops when its parent is no smaller and its children are no larger, which restores heap order. After `remove`, the element moved into the hole can be out of place in either direction, so both sifts run; at most one of them moves it.

`topK` is correct because the next most urgent element is always a child of an element already output (heap order). The frontier therefore always contains it. `isValid()` checks both invariants after randomized operations in the tests.

**Cost.**

| Operation | Time |
|---|---|
| push, update, remove, poll | O(log n) |
| peek | O(1) |
| topK(k) | O(k log k), independent of n, and the heap is not modified |
| expiring e activities | O(e log n) |

Space is O(n). The baseline (keep a map and sort on every read) costs O(n log n) per read.

**Failure handling.**
- Duplicate key on `push` → `IllegalArgumentException`; the service uses `upsert`.
- `peek`/`poll` on an empty heap → `NoSuchElementException`.
- Invalid fields → HTTP 400.
- Full queue → HTTP 409, checked before the event is remembered, so a retry isn't mistaken for a duplicate.

**Tests:** `IndexedBinaryHeapTest`, 7 tests:
- empty heap (edge)
- single element (edge)
- polls come out in sorted order
- increase-key and decrease-key, duplicate keys
- removing from the middle
- `topK` with k > n and k = 0
- 20,000 random operations checked against a brute-force reference

`LiveQueueTest`, 7 tests:
- urgency order
- an update moves the same activity rather than adding a row
- expiry at exactly the time-to-live (boundary)
- a duplicate is ignored
- the fingerprint window
- a quick running → attention → running change; queue version
- the capacity limit (boundary)

---

## 2. Bloom filter: duplicate event screening (Unit 6 · CO5)

**Code:** `algo/bloom/BloomFilter.java`, used by `live/EventDeduplicator.java`.

**Problem.** The same event can arrive more than once:
- CI systems retry webhooks
- a Claude Code hook can end up registered twice (this happened while building Notchi)
- scripts re-run `island push`

A replay is harmful. If "deploy running" is retried *after* "deploy done", the island would roll the job back to running and announce it again. Most events are new, so checking each one against the full event log is wasted work, and that log would live in a database or on disk in a larger deployment.

**Inputs.** An event id: either the sender's `eventId`, or a content fingerprint `id|state|title|subtitle|progress@⌊t/2s⌋`.

A fingerprint is only checked when the event is identical to what the activity currently shows. An event that changes the activity is applied and its fingerprint remembered, so a quick running → attention → running is never mistaken for a repeat.

Configuration: planned keys n ∈ [10, 50M] and target false-positive rate p ∈ [0.0001, 0.5].

**Output.** NEW, NEW_AFTER_FALSE_POSITIVE or DUPLICATE.

**Sizing.**

```
m = ⌈−n · ln p / (ln 2)²⌉            bits
k = round((m / n) · ln 2)             hash functions
FPR after n inserts ≈ (1 − e^(−kn/m))^k
```

For n = 10,000 and p = 1% this gives m = 95,851 bits (11.7 KB) and k = 7.

**Hashing.** Two 64-bit hashes of the UTF-8 bytes: FNV-1a, and a MurmurHash3-style mix with the fmix64 finaliser, forced odd. Bit i is `(h1 + i·h2) mod m` for i = 0…k−1. This is Kirsch–Mitzenmacher double hashing, which performs like k independent hashes.

```
check(id, now):
  if not bloom.mightContain(id):            # some bit is 0 → definitely never added
      record(id); return NEW                # exact log not consulted
  if log[id] exists and now − log[id] ≤ 24h:
      return DUPLICATE                      # confirmed
  if log[id] exists: record(id); return NEW # a repeat from outside the window (counted as expiredRepeats)
  record(id); return NEW_AFTER_FALSE_POSITIVE    # the filter was wrong; event still accepted
record(id):
  log[id] = now (moved to the end, so the log stays oldest-first); bloom.add(id)
  if bloom.inserted ≥ capacity: drop log entries older than 24h
                                capacity = max(n, 2·|log|); rebuild bloom from log
```

**Correctness.**
- *No false negatives:* `add` sets all k bits of a key, and bits are never cleared. So `mightContain` is true for every key added, and a duplicate always reaches the exact check.
- *No lost events:* an event is dropped only when the exact log confirms it. A false positive costs one extra lookup, never a lost event. This follows the course rule that Bloom hits are treated as "possibly present".
- *Rebuild:* the new filter is built from every id still in the log, so the no-false-negative property survives rebuilds. Its capacity is at least twice the log size, so it is at most half full when born. Capacity doubles like a dynamic array, so the rebuild cost is amortized O(1) per event (Unit 1, amortized analysis).

**Cost.**
- `add` / `mightContain`: O(k + |id|).
- Space: m bits, about 1.2 bytes per key at 1% regardless of key length. An exact `HashSet<String>` measured about 63 MB for 1M ids, against 1.1 MB for the filter.
- Hash-set lookups are faster in memory (Java caches String hash codes). The filter's gains are memory, and that it skips the authoritative log for the ~99% of events that are new.

**Failure handling.**
- Invalid sizing (n ≤ 0, p ∉ (0, 1), filter over 2³¹ bits) → `IllegalArgumentException` → HTTP 400.
- Blank or null ids are rejected.
- Retention: an id older than 24 h is accepted again and counted as `expiredRepeats`.

**Tests:** `BloomFilterTest`, 7 tests:
- an empty filter contains nothing (edge)
- no false negatives over 50,000 keys
- the sizing formulas
- measured FPR between 0.5% and 1.5% for a 1% target, over 200,000 probes
- `add` reports newness
- an overfilled filter (10× the plan) matches the theoretical FPR (boundary)
- invalid parameters

`EventDeduplicator`, 5 tests:
- the basic flow
- a deliberately overloaded filter still lets every one of 5,000 distinct events through
- retention window
- rebuild and growth without losing ids
- validation

---

## 3. Trie: launcher search (Unit 4 · CO3)

**Code:** `algo/trie/Trie.java`, used by `launcher/Launcher.java`.

**Problem.** Typing in the island's Claude bar should instantly show matching apps, pinned terminal tabs and Notchi commands (e.g. "Theme Ocean"), most-used first. "code" should find "Visual Studio Code", and "cut p" should find "Final Cut Pro".

**Inputs.**
- Catalog items `{id, label ≤ 120 chars, kind ∈ {app, tab, command}, path?}`, at most 20,000. The Mac app scans /Applications, /System/Applications and ~/Applications, and adds the pinned tabs and commands.
- Query: a prefix of at most 100 characters, and k ∈ [1, 20].

**Output.** Up to k items with a word starting with the prefix, ranked by launch count, then label A→Z ignoring case, then id.

**Indexing.** Labels are normalised: lower-cased, with runs of non-alphanumerics turned into one space. This works on Unicode code points, so 𝐀 counts as a letter. Each item is inserted under every *word start*: "visual studio code", "studio code" and "code". A node's children are kept in a sorted `char[]` with a parallel `Node[]` (binary search). This takes far less memory than a hash map per node, so 100k items fit in about 550k nodes.

```
insert(item):   for key in wordStarts(normalize(label)): walk/create nodes; node.items += item
search(p, k):   n = walk(normalize(p)); if none → []
                best = bounded min-heap of size k            # least relevant at the root
                DFS the subtree under n; for each item not seen yet (an item can appear under 2 words):
                    if |best| < k: push; else if item > best.min: pop min; push item
                return best, most relevant first
recordUse(id):  item.weight += 1                             # O(1): items are shared objects
remove(id):     for each key: unlink item; prune nodes left with no children and no items
```

**Correctness.** Every word start of every label is a path from the root. So an item belongs in the results for p exactly when one of its keys has p as a prefix, which means it sits in the subtree under p. The DFS visits that whole subtree, and the `seen` set keeps each item once. The bounded heap holds the k best seen so far: an item is evicted only by a strictly better one. When the DFS ends it holds the top k. The tests compare against the linear-scan baseline on 300 random queries over 3,000 labels, and check that the incremental node count matches a full recount after inserts and removals.

**Cost.**

| Operation | Time |
|---|---|
| insert | O(L · w): label length × words |
| search | O(p + S + m log k): S nodes under the prefix, m items there |
| recordUse | O(1) |
| remove | O(L · w) |

Space is O(total indexed characters). The baseline scans all n items, O(n · w), on every keystroke. Longer prefixes shrink S sharply: measured 63× faster at 100k items with 4-letter prefixes, 6× with 1-letter ones.

**Failure handling.** All of these → 400:
- duplicate ids
- blank or symbol-only labels
- labels over 120 characters
- negative weights
- k ≤ 0 or k > 20
- unknown kind

When a whole catalog is uploaded, items that fail these checks (e.g. a 🚀-only tab name) are skipped and listed in the response; the rest are indexed. Unknown id on `use` → 404. An empty prefix returns the k most-used items.

**Tests:** `TrieTest`, 7 tests:
- an empty trie and unmatched prefixes (edge)
- ranking by weight
- word-start matching ("code", "stud", "cut pro", punctuation)
- `recordUse` and case-insensitive alphabetical tie-breaking
- validation (boundary: a 121-character label, an emoji-only label, letters outside the BMP)
- `remove` with pruning
- random labels against the linear baseline

---

## 4. Randomized Quickselect: Claude ETA (Unit 6 · CO5)

**Code:** `algo/select/RandomizedSelect.java`, used by `stats/DurationStats.java`. Baselines are in `SelectBaselines.java`.

**Problem.** Every finished Claude Code run in a pinned tab (reported by the hooks) is recorded as a duration. While Claude works, the tab shows "elapsed / ~usual". "Usual" is the median (p50), and the tooltip adds p90. Run times are heavily skewed, so a percentile describes them better than a mean.

**Inputs.**
- Durations in seconds, in (0, 7 days], per tab key (a tab name of at most 100 characters).
- Percentile p ∈ [0, 100], nearest-rank method: rank = ⌈p · n / 100⌉. Multiplying first matters: p/100 · n gives 55.000000000000007 for p = 55 and n = 100, which would round up to the wrong rank.
- A tab with fewer than 5 runs uses all tabs' runs. With fewer than 5 overall: `enough: false`.

**Output.** p50, p90, p99, min, max, and the number of comparisons made.

```
select(a, k):                               # k-th smallest, 0-based; works on a copy
  lo, hi = 0, n−1
  loop:
    if lo == hi: return a[lo]
    pivot = a[uniform random index in lo..hi]
    three-way partition a[lo..hi] → [< pivot | = pivot | > pivot] = [lo..lt−1 | lt..gt | gt+1..hi]
    if k < lt: hi = lt − 1
    elif k > gt: lo = gt + 1
    else: return pivot
```

**Correctness.** After partitioning, everything before `lt` is smaller than the pivot and everything after `gt` is larger. So the k-th smallest is in the left part, the right part, or equals the pivot, and the loop continues only in the part containing rank k. The range shrinks every round, because the pivot block is never empty, so the loop terminates. The answer is always exact: randomness only affects the running time, which is what makes this a Las Vegas algorithm. The three-way split handles many equal durations; an all-equal array finishes in one pass.

**Cost.**
- Expected O(n). The expected comparisons for the median with a two-way partition are at most ≈ 2(1 + ln 2)·n ≈ 3.4n. The three-way loop counts up to two comparisons per element, and measured about 5n flat from 10k to 1M values.
- Worst case O(n²), but only with vanishing probability. No input can force it.
- O(1) extra space: iterative and in place.
- Baselines:
  - **Sort-and-index**, O(n log n): measured 6× slower at 1M values.
  - **Fixed first-element pivot**, O(n²) on sorted input: 384M comparisons vs 124k for n = 32,000. Durations logged in increasing order are exactly that kind of input.

**Failure handling.** All of these → `IllegalArgumentException` → 400:
- empty data
- NaN values
- k out of range
- p ∉ [0, 100]
- durations ≤ 0 or over 7 days
- blank or long keys

A CSV import is all-or-nothing, and reports the line number of the first bad line. Only a first line ending in "seconds" is treated as a header. Damaged lines in the history file on disk are skipped, so they can't stop the backend.

**Tests:** `RandomizedSelectTest`, 7 tests:
- one element, and every invalid input (edge)
- every rank of a small array; the input is not modified
- all-equal and heavily duplicated data
- nearest-rank percentiles p0…p100 on 1..100, including p55 and p7 (boundary)
- 500 random arrays against sort-and-index
- sorted input: randomized stays linear, the first pivot goes quadratic
- negative values and ±∞

`DurationStatsTest`, 5 tests:
- not enough history
- percentiles
- fallback to all tabs
- CSV persistence and import validation
- invalid input

---

## 5. Aho–Corasick: sorting notes (Unit 4 · CO3)

**Code:** `algo/text/AhoCorasick.java` (KMP baseline in `algo/text/Kmp.java`), used by `notes/NoteClassifier.java`.

**Problem.** A note or a copied clip has to be filed as a reminder, to-do, link, password/key, contact, code, idea or plain note. Evidence comes from about 150 cue words and phrases ("password", "remind", "don't forget", "buy", "def ", "what if"…). Searching for each one separately re-reads the text 150 times.

**Inputs.**
- Text up to 20,000 characters.
- `now` and the user's UTC offset, to resolve "tomorrow 5pm".

**Output.** A category, a confidence (top score ÷ total), human-readable reasons, extracted links/e-mails/phones, a due time, and the secret spans to hide.

**The automaton.** A trie of all cue words. Each node also gets:
- a **failure link:** the longest proper suffix of the node's string that is also in the trie. This is KMP's prefix function, generalised from one pattern to many.
- an **output link:** the nearest node on the failure chain where a cue ends.

```
build:  BFS from the root
          for each edge u –c→ v:
            f = fail[u]
            while f ≠ root and f has no c-child: f = fail[f]
            fail[v] = f's c-child (or root)
            out[v]  = fail[v] if a cue ends there, else out[fail[v]]
search: state = root
        for each character c:
          while state ≠ root and state has no c-child: state = fail[state]
          state = child(state, c) or root
          report the cues ending at state, then follow output links
```

**Scoring.** One token scan adds structural evidence:
- links: http(s)://, www., or a domain with a known TLD;
- e-mails;
- phone numbers: whole tokens with 10–15 digits;
- secrets:
  - known key prefixes such as `ghp_` or `sk-…`;
  - long, mixed-case, high-entropy tokens (UUIDs, hex hashes, paths and file names are excluded);
  - a note that is just one password-shaped token, like `Tr0ub4dor&3`;
  - the value after "password:", "password for netflix:" or "password is", hidden to the end of the line, so passphrases are hidden whole;
  - the password in `user:pass@host`, and credential-looking query values in URLs (`?access_token=…`);
  - private-key blocks;
- a due time ("in 20 min", "tomorrow at 5pm", "friday 9:30am", "tonight"…);
- code punctuation.

Cue words count once each and must be whole words where it matters. "pass" doesn't fire inside "passport".

The category with the highest score wins, and ties go to the earlier category in the list. Credential words without an actual secret are down-weighted (×0.4), so "the secret to good coffee" stays a note. Links, e-mails and phone numbers that fall inside a secret are dropped from the result, so nothing secret reaches the stored reasons or URLs.

A few rules keep due times sensible:
- A dot only makes a time with am/pm or after "at" ("2.49" is a price).
- Hours 1–7 without am/pm mean the afternoon ("at 5:30" is 17:30).
- A weekday includes today if the time is still ahead.
- "today" with no time, said late in the day, means an hour from now rather than the past.

**Correctness.** Every occurrence of a cue ending at position i corresponds to a suffix of the text up to i that is a trie path. After reading character i, the automaton is at the longest such suffix: the same invariant as KMP, proved the same way by induction on i. All shorter cues ending at i are on its failure chain, and the output links visit exactly those that end a cue. The test compares against KMP run per pattern on 300 random texts × 40 random patterns.

**Cost.**
- Build: O(L) for L total cue length (once, at start-up).
- Search: O(n + z) for n characters and z matches, independent of the number of cues.
- Baseline (KMP per cue): O(k · n).
- Measured: 687× faster at k = 10,000.

**Failure handling.**
- Over-long text → 400.
- Secrets are redacted before a note is stored (the original goes to the macOS Keychain, from the app).
- A clip with a secret is not stored at all.
- A wrong guess can be corrected (**Move to**), and the user's choice is kept.

**Tests:**
- `AhoCorasickTest`, 6 tests: edges; the classic he/she/his/hers example; overlapping patterns; case and payloads; random texts against KMP; the KMP prefix function.
- `NoteClassifierTest`, 8 tests:
  - credentials and redaction;
  - passphrases, "is", URLs and lone passwords, with nothing leaking into reasons or URLs;
  - no false credentials (UUIDs, file names, "pin the tab", "password manager");
  - due times, including prices and versions that aren't times, afternoon hours, today's weekday, and "9 am already passed → tomorrow";
  - "today" said late in the day;
  - the other categories;
  - boundaries;
  - reasons and whole-word matching.
- `NotesStoreTest`, 5 tests: secrets never stored or searchable; search, filter and pinning; due reminders fire once; a client-chosen id, and filing by hand under Passwords hides the text; persistence and validation.

---

## 6. Suffix array: clipboard and note search (Units 4 + 1 · CO3)

**Code:** `algo/text/SuffixIndex.java`, used by `clipboard/ClipboardHistory.java` and `notes/NotesStore.java`.

**Problem.** "Where was that link I copied yesterday?" Search must find text *anywhere* inside a clip, not just at the start of a word (which is what the launcher trie does).

**Inputs.**
- Documents: up to 500 clips (the first 4,000 characters of each), or the notes.
- A query of up to 200 characters, matched case-insensitively.

**Output.** The documents containing the query.

**Construction (prefix doubling).** The documents are lower-cased and joined with a separator `\0` that no query contains, so no match can cross two documents.

```
rank[i] = rank of character i (characters compressed to 0..σ−1)
sa = suffixes sorted by first character (counting sort)
for k = 1, 2, 4, …:
    order by second key: suffixes with i + k ≥ n first, then sa[j] − k for sa[j] ≥ k
    stable counting sort of that order by rank[i]          ← radix sort on (rank[i], rank[i+k])
    new ranks: equal pairs share a rank
    stop when all n ranks differ
search(q): lo = first suffix ≥ q, hi = first suffix > q·∞   (two binary searches)
           documents of sa[lo..hi), each once
```

**Correctness.** After the round with step k, suffixes are sorted by their first 2k characters. A pair (rank of the first k, rank of the next k) orders suffixes exactly as their first 2k characters do, and the radix sort sorts by that pair. It ends when every rank is distinct, which means the full suffixes are sorted (at most ⌈log₂ n⌉ rounds). All suffixes starting with q are contiguous in sorted order, and the two binary searches find that block. Tests compare the array against a brute-force sort of 200 random strings, and search against a KMP scan for 300 queries over 300 documents.

**Cost.**
- Build: O(n log n) time, O(n) extra memory.
- Query: O(m log n + occurrences).
- Baseline: O(n) per query (scanning every clip with KMP).
- Measured: 55–81× faster per query. The index is rebuilt only when the history has changed and someone searches.

**Failure handling.**
- Empty query → nothing.
- Query containing the separator → nothing.
- Over-long query → 400.
- Damaged entries in the saved history are skipped on load.

**Tests:**
- `SuffixIndexTest`, 6 tests: edges (no documents, empty documents and queries); "banana" and "aaaa"; substring search; no cross-document matches with a limit (boundary); random strings against brute force and against a scan; Unicode and a stray separator.
- `ClipboardHistoryTest`, 5 tests: newest first, repeats merged; secrets skipped; search and index rebuild; the 500 cap with pinned clips (boundary); persistence and kinds.

---

## 7. Segment tree: screen time (Unit 3 · CO2)

**Code:** `algo/tree/SegmentTree.java`, used by `activity/ScreenTime.java`.

**Problem.** Notchi records which app is in front, as spans. The Activity page asks range questions:
- time in an app today, or between two times;
- 24 hourly totals and the busiest hour;
- for Workspaces, which apps were used in each 15-minute block.

At the same time, tracking keeps adding seconds to minutes.

**Inputs.**
- Spans `{app, name, start, end}`. Each must end after it starts, be at most 12 h long and not end in the future.
- The UTC offset, which sets the local day and minute.

**Output.** Totals, per-app times, hourly bars, busiest hour, longest focus run, range sums.

**Structure.** For each day: one tree per app plus one for all apps. Each has 1,440 leaves, and a leaf holds the seconds that app was in front during that minute. The tree is a complete binary tree in an array, with leaves at [size, 2·size). Each internal node stores the sum and the max of its range.

```
add(i, x):  p = size + i; leaf += x; walk up: sum[p] = sum[2p] + sum[2p+1], max[p] = max(...)
sum(l, r):  a = l + size, b = r + size
            while a < b: if a odd: take a++; if b odd: take --b; a /= 2; b /= 2
argMax(l,r): target = max(l, r); descend from the root to the leftmost leaf in [l, r) with value ≥ target
```

A span is split into minute pieces, across midnight too. A minute never gets more than 60 seconds. Spans can't overlap: a re-sent span only counts from where the last one ended.

**Correctness.**
- *Invariant:* every node holds the sum and max of its leaves.
- `add` restores it along the only path that changed.
- The iterative query takes a node exactly when it lies wholly inside [l, r) and its parent doesn't. This covers the range with at most two nodes per level and no overlaps.
- The tests compare against a plain array over 20,000 random updates and queries.

**Cost.**
- Update and query: O(log n). Space: O(n).
- Plain array: O(r − l) per query. Prefix sums: O(n) per update.
- Measured for 20,000 mixed operations over a million buckets: 3.3 ms, against 806 ms (array) and about 3.2 s (prefix sums).

**Failure handling.**
- Invalid spans → 400.
- Bad UTC offsets → 400.
- Overlapping or re-sent spans → clamped.
- Idle for 2 minutes, sleep, or a locked screen → the app stops the span.
- Days older than 35 are dropped.
- Damaged lines in the saved history are skipped.

**Tests:**
- `SegmentTreeTest`, 5 tests: edges (empty ranges, size 1); sums, maxima and argmax over minute buckets; set and add; bounds; random operations against a plain array.
- `ScreenTimeTest`, 6 tests: empty; summary and busiest hour; no double counting; a span across midnight and longest focus (boundary); validation and persistence; a batch with one bad span changes nothing, and a torn history file still loads.

---

## 8. Union–find: workspaces (Unit 2 · CO2)

**Code:** `algo/dsu/DisjointSet.java`, used by `activity/Workspaces.java`.

**Problem.** Group apps that you keep using together, so one click opens the whole group. "Together" is transitive: Figma–Slack plus Slack–Chrome is one design workspace. So the groups are the connected components of a "used together" graph.

**Inputs.** The last 14 days of screen time, cut into 15-minute blocks. For each block, the apps that were in front for at least a minute.

**Output.** Up to 6 workspaces, each with 2–6 apps, ordered by total time.

**Steps.**
1. Count, for every pair of apps, the blocks they share.
2. Leave out system apps such as Finder, Notchi and System Settings. Otherwise they would join everything into one group.
3. Union two apps when they share at least 3 blocks and their **Jaccard similarity** (shared blocks ÷ blocks where either is used) is at least 0.4.

   A browser used with everything has a low similarity to each single app, so it can't chain "coding" and "design" into one group.
4. Every set with two or more apps is a workspace.
5. An app left on its own joins each workspace it is used with in at least half of that workspace's blocks. So Chrome can belong to both "coding" and "design".
6. Workspaces you've dismissed are hidden.

```
find(x):     follow parents to the root, then point every node on the path at the root   (path compression)
union(a, b): ra, rb = find(a), find(b); if equal: return
             attach the lower-rank root under the higher one; equal ranks: rank += 1  (union by rank)
```

**Correctness.**
- After each union, two elements share a root exactly when a chain of unions connects them.
- Path compression only re-points nodes at their own root, so it never changes a set.
- Union by rank keeps trees O(log n) deep even without compression. With compression, m operations cost O(m α(n)).
- The tests compare against BFS connected components over random edges, and check a 100,000-element chain.

**Cost.**
- Building the groups: O(B · a² + P α(A)) for B blocks of at most a apps and P pairs. That is tiny for a real Mac.
- The data structure itself: O(α(n)) per operation, against O(n + e) per BFS recomputation.
- Measured: 766× faster at 100,000 apps with 1,000 questions.

**Failure handling.**
- No data → no workspaces.
- Apps used together only once → not grouped.
- Dismissing needs at least two apps.
- Apps that aren't installed any more simply don't open.

**Tests:**
- `DisjointSetTest`, 6 tests: edges; transitivity; repeated unions; groups; a 100,000-element chain (boundary); random unions against BFS.
- `WorkspacesTest`, 5 tests: empty; the demo week gives a coding and a design workspace, with Finder ignored as a hub; a browser used with both joins both instead of merging them; one-off co-use isn't grouped; dismissal.

---

## Supporting code (not assessed algorithms)

- `json/Json.java`: a recursive-descent JSON parser and writer. It caps nesting at 64 levels so deep input can't overflow the stack. `JsonTest` has 5 tests.
- `http/ApiServer.java`: a router on the JDK HTTP server.
  - It maps exceptions to 400, 401, 403, 404, 405, 409, 413 and 500.
  - It listens on 127.0.0.1 only, and refuses requests that carry an `Origin` header (web pages) or a foreign `Host` (DNS rebinding).
  - When started by Notchi, it also requires a secret `X-Notchi-Token` (kept in the Keychain) on everything except `/api/health`.
- `http/NotchiApi.java`: the endpoints and input validation. Every LIVE response carries a queue `version`, so the app ignores an older order that arrives after a newer one. `ApiServerTest` has 8 end-to-end tests that make real HTTP calls against a server on a random port.
