# ADR 0013: Index Metadata Sync

- Status: Proposed
- Date: 2026-06-25
- Deciders: DS project
- Component: `DS.Storage.Index`, `DS.Storage.Schema`, `DS.Reconciler`

## Context

`DS.Storage.Index` (see ADR-0001 for storage shape) is local per node. The
metadata table `:indexes` records which `{entity, field}` pairs are indexed.
The forward (`:ordered_set`) and reverse (`:set`) ETS tables for each pair
exist only on nodes that have been told the index has been created.

Today, the only way a node learns about an index is to receive a
`{:create_index, entity, field}` cast from a peer **at the moment** another
node calls `DS.Storage.Index.create_index/2`. There is:

- no `handle_continue(:sync, ...)` at startup,
- no periodic resync timer,
- no `:nodeup` listener,
- no fallback path that builds missing index tables when a `where/4` query
  arrives for a known-but-uninstalled index.

A node that joins the cluster after `create_index/2` was called has an empty
`:indexes` table. Subsequent calls to `Index.where/4` on that node hit the
"no index" branch and silently fall back to `full_scan` of `:primary`. This
is a correctness hazard for index-dependent code that assumes the index
exists, and a performance cliff for any query that lands on the
under-indexed node.

`DS.Storage.Schema` already solved the equivalent problem for schemas:

- `init/1` emits `{:continue, :sync}` so the first thing the GenServer does
  after start is pull schemas from a peer via
  `:erpc.call(peer, __MODULE__, :all_schemas, [], 5_000)`.
- `register/2` casts the new schema to every current peer.
- A periodic `:resync` timer re-pulls schemas from a peer in case a cast was
  lost during a partition.

This ADR proposes the same pattern for indexes.

## Key observation

**Indexes are local materialized views of the local `:primary` table.** Both
forward and reverse tables on a given node are derived from the records
stored on that node's `:primary`, via `Primary.put`'s `update_indexes/2`
side effect. The Reconciler reinforces this in both directions (ADR-0001).

A consequence: **only metadata needs to be synced between nodes** — the list
of `(entity, field)` pairs that should be indexed. Forward/reverse table
*contents* are derived from local `:primary` data and do not need to ship
between nodes. They populate naturally as writes flow in:

- A node joins with empty `:primary` and empty index tables.
- Writes arrive via `Primary.remote_write` (= `Primary.put/3` with a clock).
  Each write triggers `update_indexes` → `Index.update_index` for every
  field.
- If the empty index tables exist, they fill up in lockstep with `:primary`.
- The Reconciler's periodic pass fixes any drift.

Therefore, syncing the index metadata at startup (and periodically) is
sufficient to bring a joining node to a steady state without ever shipping
forward/reverse rows over the wire.

## Decision

Mirror `DS.Storage.Schema`'s sync mechanism in `DS.Storage.Index`:

1. **On startup** — `init/1` emits `{:continue, :sync}`. `handle_continue/2`
   calls `:erpc.call(peer, DS.Storage.Index, :index_pairs, [], 5_000)` on the
   first reachable peer in `Node.list()`. For every `{entity, field}` in the
   response, run `do_create_index(entity, field)` locally to build empty
   forward/reverse tables and insert the `:indexes` metadata row.

2. **Periodic resync** — schedule `:resync` on a configurable interval
   (default: `DS.Config.resync_interval/0`, matching Schema). On `:resync`,
   re-pull index pairs from a peer. New pairs are created locally; existing
   pairs are no-ops. Empty pairs that should have been created but were
   missed get caught on this pass.

3. **No content shipping.** The actual forward/reverse table rows are never
   transferred. They are populated by:
   - Normal write traffic via `Primary.put` → `update_indexes`.
   - The existing `Reconciler` (ADR-0001), which fixes stale and orphaned
     entries from the local `:primary`.

`index_pairs/0` is already exposed (`lib/storage/index.ex`), so no new
public API is required for the pull side.

## Consequences

### Positive
- A node joining after `create_index/2` ends up with the same set of indexed
  pairs as the rest of the cluster, without manual intervention.
- The fix is symmetric with Schema's existing sync, so anyone who
  understands Schema's lifecycle automatically understands Index's.
- No new wire format or data shipping; reuses `index_pairs/0` and
  `do_create_index/2`, both already in the module.
- Tolerates dropped casts: a lost `{:create_index, ...}` cast (e.g. during a
  partition) is repaired on the next resync without operator action.

### Negative
- Adds a periodic `:erpc.call` per node. Cheap (small payload, infrequent)
  but non-zero.
- The first call after startup may briefly fail if no peer is reachable. The
  same fallback Schema uses (`{:halt, :ok}` on the first success, otherwise
  `:no_peer`) applies — a node alone in the cluster sees an empty
  `Node.list` and skips sync, which is the correct behaviour.
- A node that learns about an index "late" via resync has an empty forward
  table until enough writes flow through. Range queries against it return
  empty result sets for records it doesn't own, even though other nodes hold
  forward entries for records they own. This is the same behaviour as today
  for the very first writes after `create_index/2`, and matches the
  per-node-locality semantics of indexes — but is worth documenting so
  callers don't assume a global view.

### Negative — what this ADR does **not** address
- **Data rebalancing.** If slot ownership ever changes (e.g. a node joins
  and gets some slots reassigned), the records for those slots must move
  too. The current Rebalancer only updates `:routing`; it does not move
  primary records. When data movement is added, the path that writes
  records onto the new owner must trigger `update_indexes` (i.e. go through
  `Primary.put`, not `Primary.bulk_put`). Out of scope here; flagged for a
  future ADR.

## Alternatives considered

1. **Ship forward/reverse contents between nodes.** Rejected. The contents
   on each node should reflect that node's local `:primary` — shipping
   contents from a peer would mix in entries for records the joining node
   doesn't own, breaking the per-node-locality model and creating its own
   reconciliation problem.

2. **Lazy creation on first query.** When `Index.where/4` finds no index for
   a known `{entity, field}`, create it on the fly and full-scan once.
   Rejected: requires the node to know which `{entity, field}` pairs are
   "real" indexes vs. typos, which is exactly the metadata problem we're
   trying to solve. Also defers cost to the first query, which is the wrong
   moment.

3. **Push-only (cast on `:nodeup` from every existing peer).** Rejected.
   Listening for `:nodeup` and pushing all known index pairs to the joining
   node works but creates a thundering-herd on cluster events and depends
   on `:net_kernel.monitor_nodes` being subscribed in `DS.Storage.Index`.
   The pull-on-startup pattern Schema uses is simpler and already proven in
   this codebase.

4. **Do nothing; document the gap.** Rejected. Silent full-scan fallback is
   the kind of surprise that ages badly — it manifests as performance
   degradation that's hard to attribute back to "I forgot to recreate this
   index on the new node".

## Related

- ADR-0001 — Index entry storage; the local data model this sync supports.
- `DS.Storage.Schema` — the pattern being mirrored.
