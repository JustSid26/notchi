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

Measured numbers are in [benchmarks.md](benchmarks.md).

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

## Supporting code (not assessed algorithms)

- `json/Json.java`: a recursive-descent JSON parser and writer. It caps nesting at 64 levels so deep input can't overflow the stack. `JsonTest` has 5 tests.
- `http/ApiServer.java`: a router on the JDK HTTP server. It maps exceptions to 400, 403, 404, 405, 409, 413 and 500. It listens on 127.0.0.1 only, and refuses requests that carry an `Origin` header (web pages) or a foreign `Host` (DNS rebinding).
- `http/NotchiApi.java`: the endpoints and input validation. Every LIVE response carries a queue `version`, so the app ignores an older order that arrives after a newer one. `ApiServerTest` has 6 end-to-end tests that make real HTTP calls against a server on a random port.
