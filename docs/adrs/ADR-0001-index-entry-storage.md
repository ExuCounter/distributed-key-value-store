# ADR 0001: Index Entry Storage — Dual (Forward + Reverse) Indexes

- Status: Accepted
- Date: 2026-06-18
- Deciders: DS project
- Component: `DS.Storage.Index`, `DS.Reconciler`, `DS.Store`

## Context

The distributed KV store must support two access patterns over the same
indexed field (for example, `person.age`):

1. **Range queries** — `where(:person, :age, 25, 50)` must return all ids whose
   value falls in a range, efficiently. This is the primary reason indexes
   exist in this system.
2. **Point updates / deletes / reconciliation by id** — when a record changes
   or is checked, we must find the *current* indexed value for a given id so we
   can remove the stale entry and write the correct one.

A single index structure cannot serve both patterns efficiently:

- An index keyed by **value** (sorted) makes range scans cheap (O(log n) seek +
  sequential read) but makes "find the entry for id X" an O(n) full scan,
  because ids are scattered across the value ordering.
- An index keyed by **id** makes point lookups cheap (O(1)) but makes range
  scans an O(n) full scan, because values are unordered.

Each node stores only the data it owns (consistent hashing by key), so indexes
are local per node. Index maintenance happens on the write path and again,
asynchronously, in the anti-entropy reconciler. Both paths need the
"find current value by id" operation; without it, every update and every
reconciliation step degrades to O(n), making reconciliation O(n^2) overall.

## Decision

Maintain **two ETS tables per indexed `{entity, field}`**:

- **Forward index** — `:index_<entity>_<field>`, type `:ordered_set`, tuples
  `{value, id}`. Used for range queries.
- **Reverse index** — `:rindex_<entity>_<field>`, type `:set`, tuples
  `{id, value}`. Used to find the current indexed value for an id in O(1).

A metadata table `:indexes` maps `{entity, field}` to the forward index name and
records that the pair is indexed.

Tuple-order convention (must be applied consistently everywhere):

- Forward: value first  → `{value, id}`
- Reverse: id first      → `{id, value}`

All index mutations update **both** tables:

- `update_index/4` — looks up the old value from the reverse index, deletes the
  stale forward entry, then writes the new forward and reverse entries. Because
  the reverse table is a `:set` keyed by id, re-inserting overwrites the old
  reverse entry automatically.
- `delete_index_entry/_` — removes the entry from both tables.
- `create_index/2` — creates both tables.
- `fix_entry/5` (reconciler) — repairs both tables from primary, the source of
  truth.

## Source of truth

The **primary table is the single source of truth**. Both indexes are derived
data and may drift after partial failures (e.g. primary write succeeds, index
write crashes). The reconciler rebuilds index entries from primary; it never
treats an index as authoritative.

## Reconciliation (anti-entropy)

Two linear passes, run periodically per node:

- **Pass 1 — primary → index**: walk primary in batches; for each indexed field,
  compare the true value (from primary) against the reverse index lookup by id.
  - equal              → no-op
  - different (stale)  → delete stale forward entry, write correct forward+reverse
  - missing            → write forward+reverse
  This catches missing and stale entries. O(n) thanks to the reverse index O(1)
  lookup (without it this pass would be O(n^2)).

- **Pass 2 — index → primary**: walk the forward index in batches; for each
  `{value, id}`, check primary. If the id no longer exists, or primary's value
  differs, delete the orphan from both tables. This catches orphans that pass 1
  cannot see, because primary has no pointer to them (e.g. a deleted record whose
  index cleanup failed). O(m).

Both directions are required: primary→index catches "missing", index→primary
catches "orphaned". Either pass alone is insufficient.

## Consequences

### Positive
- Range queries stay O(log n + k).
- Updates, deletes, and reconciliation stay O(1) per entry; reconciliation stays
  O(n + m) linear instead of O(n^2).
- `update_index` becomes self-contained: it no longer requires the caller
  (`DS.Store.put`) to fetch and pass the old value, since it reads it from the
  reverse index.

### Negative
- Roughly 2x memory per indexed field (two tables instead of one).
- Two structures to keep in sync; a partial failure can desync forward vs reverse
  in addition to desyncing from primary. Mitigated by anti-entropy treating
  primary as source of truth and rebuilding both.
- Tuple-order convention is easy to get wrong (forward = value-first, reverse =
  id-first). Centralize all index reads/writes in `DS.Storage.Index` so the
  convention lives in exactly one module.

## Alternatives considered

1. **Forward index only.** Rejected: updates and reconciliation by id become
   O(n) scans (`:ets.match` by id), making reconciliation O(n^2).
2. **Reverse index only.** Rejected: range queries become O(n) full scans,
   defeating the purpose of having an index at all.
3. **Periodic full rebuild** (drop and rebuild indexes from primary). Rejected
   as the primary mechanism: simpler and guaranteed-consistent, but expensive,
   and range queries are unavailable during rebuild unless built into a shadow
   table and swapped. May be kept as an occasional, lower-frequency safety net
   in addition to the two-pass reconciler.
4. **Store old value alongside each write and pass it through the call chain.**
   Rejected: pushes index bookkeeping into `DS.Store` and the network path, and
   still doesn't help the reconciler, which has no caller-supplied old value.
