# ADR 0020: Per-Field Clocks and CRDT Conflict Resolution

- Status: Proposed
- Date: 2026-06-30
- Deciders: DS project
- Component: `DS.Storage.Primary`, `DS.Reader`, `DS.Replicator`, `DS.CRDT`,
  `DS.Storage.Schema`, `DS.Storage.Index`

## Context

The Schema module accepts a per-field type when an entity is registered:

```elixir
DS.register_schema(:user, %{name: :lww, login_count: :counter, tags: :set})
```

The types `:lww`, `:counter`, and `:set` are declarative — they describe
how that field's value should merge across replicas. `DS.CRDT.resolve_conflict/3`
implements the merge semantics: take the max per node-slot for counters,
union for sets, vector-clock-ordered for LWW.

**None of this is wired up.** The storage in `:primary` is one tuple per
record:

```elixir
:ets.insert(:primary, {primary_key, record, clock})
```

`record` is a flat map `%{field => value}` with no per-field metadata.
`clock` is a single record-level vector clock. When two replicas diverge,
`Reader.pick_newer/2` compares the record-level clocks and picks one
*whole* record. `CRDT.resolve_conflict/3` is never called from production
code. Schema field types are silently ignored at runtime.

Concrete consequences today:

- **Concurrent edits to different fields collapse.** Node A writes
  `%{name: "Alice"}`, Node B concurrently writes `%{age: 30}`. After
  replication and read merge, one whole record wins; the other field
  update is lost. The system silently behaves like every field is `:lww`.
- **Counters don't accumulate.** Two replicas each increment a counter;
  one increment overwrites the other.
- **Sets don't union.** Two replicas each add a tag; one set replaces
  the other.
- **`CRDT.resolve_conflict/3` is dead code.** Defined, unit-tested,
  unused.

ADR-0018 (naming conventions) describes the canonical record shape as
`%{field => {type, value, clock}}` — that is the **target** shape, not
the current reality. The discrepancy is a real bug.

## The duality question

A reasonable initial design might keep both a record-level clock and
per-field clocks. That sounds redundant — and it largely is. Auditing
what each *could* be doing:

**Record-level clock — useful for:**
1. Tombstones (no fields, so per-field clocks don't apply).
2. Whole-record replacement events.
3. Cross-record ordering during anti-entropy.

**Per-field clocks — useful for:**
1. Per-field CRDT merge.
2. Independent field evolution (Node A writes `name`, Node B writes
   `age`, both preserved).

Of these, only **tombstones** genuinely need a clock outside the per-field
structure. A live record with per-field clocks doesn't need a
record-level clock — the per-field clocks together convey everything
needed for conflict resolution.

The "record-level clock as write counter" framing in ADR-0018 is weak:
it doesn't decide any merge outcome that the per-field clocks couldn't
decide.

## Decision

Restructure the storage and conflict-resolution paths so that:

1. **Live records store per-field clocks.** A field is the pair
   `{value, clock}`. The schema's type lookup is consulted only at merge
   time, not stored alongside.
2. **The record-level clock is retained only for tombstones.** A live
   record has no record-level clock. A tombstoned record has a
   `tombstone_clock` and no fields.
3. **Conflict resolution is per-field.** `Reader` and `Replicator`
   merge each field independently via `CRDT.resolve_conflict(type, ...)`,
   reading `type` from the schema.

### Storage layout

The `:primary` ETS row becomes one of two shapes:

```elixir
# Live record
{primary_key, fields, :live}
# where fields :: %{field => {value, clock}}

# Tombstoned record
{primary_key, :tombstone, tombstone_clock}
```

The third tuple slot distinguishes the two shapes at a glance. The
`Primary.get_raw/1` API decides what to expose.

### Write path

`Primary.put(primary_key, record, node)` — top-level local write from a
user `DS.put`:

1. Look up the existing row.
2. For each field in `record`:
   - If the field already exists locally, increment its clock by `node`.
   - If the field is new, start its clock at `%{node => 1}`.
3. Insert the updated `fields` map. Fields not in `record` are left
   untouched (partial updates preserved).
4. Return `{:ok, %{field => clock}}` so the caller can replicate the
   per-field clocks.

`Primary.put(primary_key, fields, :merge)` — replica write from
`Replicator.remote_write`:

1. Look up the existing row.
2. For each incoming `{field, {incoming_value, incoming_clock}}`:
   - If the local field exists, call
     `CRDT.resolve_conflict(type, {local_value, local_clock}, {incoming_value, incoming_clock})`
     and store the merged result.
   - If no local field exists, store the incoming pair.
3. Insert the merged `fields` map.

`Primary.tombstone(primary_key, node)`:

1. Compute a `tombstone_clock` by incrementing whatever clock the
   record currently has (either the existing tombstone_clock or the
   max of all field clocks).
2. Replace the row with `{primary_key, :tombstone, tombstone_clock}`.
3. Clean up indexes (unchanged).

### Read path

`Reader.read(primary_key)`:

1. Fan out `remote_read` to owner + RF-1 replicas (unchanged).
2. Collect per-replica responses. Each is either `{:ok, fields_or_tombstone, clock_or_nil}`
   or an error.
3. Reduce responses via `merge_responses/2`:
   - If both are tombstones, keep the larger `tombstone_clock`.
   - If one is a tombstone and the other live, compare the
     tombstone_clock against each field's clock. If `tombstone_clock`
     dominates every field's clock for the writing node, the tombstone
     wins. Otherwise the live record's later fields survive.
   - If both are live, merge per-field via `CRDT.resolve_conflict`.
4. Return the user-facing record: `%{field => value}` projected from
   the merged `%{field => {value, clock}}`.

For `:counter` fields, the user-facing value is the **sum** of the
G-counter map (via `CRDT.counter_value/1`), so the caller sees an
integer, not the internal `%{node => count}` map.

### Replicator

The per-field payload already carries its own clocks (each field is a
`{value, clock}` pair). No separate clocks argument is needed.

```elixir
Replicator.replicate(primary_key, fields)
# fields :: %{field => {value, clock}}
```

For tombstones, the existing two-argument form (`primary_key, :tombstone,
tombstone_clock`) is preserved.

The Replicator:

1. Fans out `Primary.remote_write(node, primary_key, fields)` to non-owner
   replicas (unchanged ADR-0007 semantics).
2. Quorum: counts `:ok` acks (unchanged ADR-0006).

The remote node's `Primary.put(_, fields, :merge)` does per-field merge
instead of blind overwrite. This closes another latent bug: today a
replica with a *newer* concurrent value gets blindly overwritten by an
incoming write, even if the incoming write is older.

### Index updates

`Storage.Index.update_index/4` is called from `Primary.put` for each
field. The current code expects `{field, value}` pairs. After this
change, it gets `{field, {value, _clock}}` — needs to project out the
value before indexing. Single-line change.

For counters, the indexed value is the **summed** counter value, not
the G-counter map. Same for any future merge type that has a "displayed
value" separate from "internal state".

## Consequences

### Positive

- `CRDT.resolve_conflict/3` becomes live code. Counters accumulate,
  sets union, LWW continues to work — per the user's schema declaration.
- Concurrent edits to different fields no longer collapse. A node
  writing `name` and another writing `age` both survive the merge.
- The `:primary` row layout is **self-describing**: `:live` and
  `:tombstone` tags make it impossible to misread a tombstone as a live
  record with weird fields.
- Replica writes are now merges, not overwrites. The "remote write
  with smaller clock blindly clobbers newer local state" bug
  (TODO in `Reader.read`) goes away as a side effect — at the write
  side rather than the read side.
- ADR-0018 (naming conventions) becomes descriptive of the code, not
  aspirational.

### Negative

- **Significant refactor.** Touches `Primary`, `Reader`, `Replicator`,
  `Storage.Index` (one call site), and every test that reads or writes
  a record via the low-level Storage API.
- **Storage size grows.** Each field carries a clock map. For records
  with many fields and many writer nodes, the per-field metadata can
  outweigh the data. Bounded but not free.
- **Tombstone-vs-live merge is the subtle case.** A tombstone written
  on Node A and a concurrent field update on Node B must compare
  cleanly. The proposed rule ("tombstone wins if its clock dominates
  every field's clock for the writing node") is correct but worth
  unit-testing carefully — it's the single hardest piece of conflict
  resolution.
- **The user-facing record projection lies a bit.** A counter's
  internal state is `%{node => count}` but the user sees the integer
  sum. Round-tripping a record through `get → put` doesn't preserve
  exact state. This is correct CRDT semantics (the integer is the
  user-visible model; the G-counter is the internal representation),
  but it's worth flagging in API documentation.

### Negative — what this ADR does **not** address

- **Read-repair.** Even with per-field merge at read, the storage on
  each node remains divergent until a write touches the merged value.
  True storage convergence requires anti-entropy, which is still a
  TODO.
- **Removal from sets.** `:set` here is a grow-only set (G-set). Real
  applications often need add-and-remove (OR-set or 2P-set). Future
  ADR; G-set is the simplest non-trivial CRDT to get right and worth
  shipping first.
- **Counter decrements.** G-counters are grow-only. PN-counters
  (positive/negative) require splitting state into `inc_map` and
  `dec_map`. Future ADR.

## Alternatives considered

1. **Single record-level clock only.** Drop `CRDT.resolve_conflict/3`
   as dead code, simplify the schema to type-free field declarations.
   Coherent but unambitious — it locks in the "every field is LWW"
   behavior as the entire system, throwing away the work already in
   `CRDT` and the unit tests for it.
2. **Per-field clocks for everything, no record-level clock.**
   Tombstones become a sentinel field (`:__tombstoned__ => {true, clock}`).
   Rejected because schemas might evolve to add new fields, and a
   sentinel-field-tombstone doesn't naturally suppress new fields a
   later writer adds. The record-level tombstone clock cleanly
   dominates "any field on this record was deleted, including ones
   you've never seen."
3. **Keep both record-level and per-field clocks, with the
   record-level clock serving as a write counter.** What ADR-0018
   describes. Rejected for the duality reasons above — the
   record-level clock doesn't decide any merge outcome the per-field
   clocks couldn't decide.
4. **Wire `CRDT.resolve_conflict/3` at read time only, leave
   `Replicator` as a blind overwrite.** Tempting because it's a smaller
   change. Rejected because it leaves the "remote write with smaller
   clock clobbers newer local state" bug unresolved — reads merge
   correctly, but storage continues to diverge in destructive ways.
   Doing the merge at the replica write side is uniformly safer and
   not much more code.

## Implementation order

1. Storage layout change in `Primary`. Update `Primary.put`,
   `Primary.get`, `Primary.get_raw`, `Primary.tombstone`. Update
   `update_indexes` call sites.
2. Schema lookup helper for per-field type. Probably a small
   `Storage.Schema.field_type/2`.
3. `CRDT.resolve_conflict/3` integration: a `merge_fields/3` helper
   that takes two field maps and the schema, returning the merged map.
4. `Reader.read` rewrite to use per-field merge.
5. `Replicator.replicate` and `Primary.remote_write` to pass
   `{value, clock}` payloads and merge on receipt.
6. `DS.where` merge_by_key: same per-field merge for cross-node
   records.
7. Update existing tests: most will break on the storage layout
   change. The fix is mostly mechanical — wherever a test asserts
   on a raw `Primary` row, the row shape has changed.

Each step compiles and is locally testable. Don't merge steps 4-6
without 1-3, but 1-3 can land independently as a no-op refactor
(storage shape change without semantic change, since merge isn't
wired yet).

## Related

- ADR-0006 — Replication factor and quorum. Per-field merge doesn't
  change W or R; quorum counts acks, not merge outcomes.
- ADR-0007 — Replicator excludes owner. The fan-out target set is
  unchanged.
- ADR-0017 — Routing propagation. Per-field merge is orthogonal to
  routing.
- ADR-0018 — Naming conventions. Currently aspirational about per-field
  shapes; will become descriptive after this ADR lands.
- ADR-0019 — `where` quorum. The `merge_by_key` helper in `DS.where`
  inherits per-field merge from the same refactor.
