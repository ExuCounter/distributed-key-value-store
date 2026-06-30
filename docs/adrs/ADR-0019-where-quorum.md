# ADR 0019: Quorum Threshold for `DS.where`

- Status: Accepted
- Date: 2026-06-30
- Deciders: DS project
- Component: `DS.where`, `DS.Storage.Index`

## Context

`DS.where/4` is a range query over a secondary index. Unlike `DS.get/2`,
which queries a single record's replica set (owner + RF-1 replicas),
`where` fans out to **every node in the cluster** via
`DS.Router.all_nodes/0`, asks each node for the index entries in the
queried range, and merges the results by key.

Before this ADR, `where` did no completeness check. The fan-out gathered
whatever responses arrived and returned `{:ok, records}` regardless of
how many nodes participated. Two failure modes followed:

1. **Crash on error tuples.** If a node returned `{:error, :node_unreachable}`
   (e.g., because it was unreachable and `forward/3` caught the exit),
   the merge step tried to call `Enum.reduce` on the error tuple, which
   raised `Protocol.UndefinedError` — tuples aren't enumerable.
2. **Silent under-representation.** If enough specific nodes failed to
   respond, records whose entire replica set was among the silent nodes
   were silently missing from the result. Callers had no way to detect
   the loss.

Defense against #1 is straightforward (guard the merge pattern). #2 is
the interesting question: **what is the right completeness threshold for
`where`?**

The naive answer is "use `DS.Config.read_quorum`" for symmetry with
`DS.get/2`. But the two operations have different correctness needs:

- `get` queries a single 3-node replica set (with RF=3). Requiring R=2
  responses out of those 3 guarantees write/read overlap with `W=1`
  (ADR-0006).
- `where` queries an index that exists *on every node*, and the "result
  set" is logically the union of all records matching the predicate.
  Completeness depends on whether any record's full replica set is
  invisible to the query.

`read_quorum = 2` is calibrated for the 3-node replica set, not for the
whole-cluster fan-out. Reusing it for `where` is wrong in two opposite
directions depending on cluster size:

| Cluster size | RF | `read_quorum = 2` outcome |
|---|---|---|
| 3 | 3 | **Too strict** — RF = N, every node has every record, so any single live node has the complete set. Requiring 2 responses needlessly errors when 1 response would have been correct. |
| 5 | 3 | **Too lax** — 2 silent nodes can hold all 3 replicas of some record. Returns an incomplete result without erroring. |
| 10 | 3 | **Way too lax** — 8 silent nodes can hide most records. Returns largely empty results without erroring. |

## Decision

The completeness threshold for `where` is:

```elixir
quorum = max(1, length(DS.Router.all_nodes()) - DS.Config.replication_factor() + 1)
```

If at least `quorum` nodes responded with a valid record list, return
`{:ok, records}`. Otherwise return `{:error, :unavailable}`.

The `max(1, ...)` clamp ensures a sensible behavior when the live cluster
size shrinks below RF (e.g., during the period after node deaths and
before rebalance): we still require at least one response, but we don't
demand more responses than there are nodes.

The merge accumulator pattern now guards against non-list payloads with
`when is_list(node_records)`, preventing the tuple-merge crash.

## Why `cluster_size - RF + 1`

A record is hidden from `where` only if **all `RF` of its replicas are
silent**. With `S` silent nodes, that requires `S >= RF`. To guarantee
no record is hidden, we need `S < RF`, i.e., `responded >= N - RF + 1`.

Walking through a 10-node, RF=3 cluster:

- 8 responses → 2 silent. 2 < 3 = RF, so no record's full replica set
  can be silent. Result is complete.
- 7 responses → 3 silent. 3 ≥ 3 = RF. If the 3 silent nodes happen to be
  the exact replica set of some record, that record is invisible.
  Threshold not met → return `:unavailable`.

In our 3-node, RF=3 cluster the threshold reduces to 1: any single live
node has every record, so one response suffices.

This formula generalizes correctly to any `(N, RF)` configuration.

## Consequences

### Positive

- `where` no longer returns silent under-representations. Either the
  result is complete, or the caller sees `{:error, :unavailable}` and
  can react.
- The threshold is **derived from a correctness invariant**, not from a
  symmetry argument with `get`. No magic numbers.
- The implementation defends against bad response shapes (`is_list`
  guard), so a future `forward/3` change that returns a different error
  shape can't silently corrupt the merge.

### Negative

- In a cluster where `cluster_size == RF`, the threshold is 1. That
  means `where` succeeds even when only one node is alive. Correct (RF
  redundancy ensures completeness), but it removes the symmetric "fail
  fast" behavior `get` has under heavy loss. Callers expecting `where`
  to fail when most nodes are down need to look at the cluster health
  separately.
- The threshold uses the **current live node count**
  (`length(Router.all_nodes())`) rather than a stable configured size.
  If many nodes die before the Rebalancer reassigns slots and updates
  routing, the threshold drops alongside the cluster, masking the loss
  during that window. The mitigation is that the Rebalancer should
  re-broadcast routing quickly (ADR-0017's 2s `resync_interval`); after
  the broadcast settles, threshold and cluster reality agree.

### Negative — what this ADR does **not** address

- **Stale routing tables.** If a node holds an outdated `:routing` and
  picks a different live set than other nodes, two callers can disagree
  on the threshold. The hop counter (ADR-0017) doesn't apply to `where`
  because `where` doesn't forward through ownership chains. Worst case
  is a slightly different threshold during the disagreement window;
  result completeness is still bounded by the same invariant.
- **Per-field CRDT merge.** `where` merges by key via the whole-record
  `Reader.pick_newer/2`. `CRDT.resolve_conflict/3` is not invoked. So
  `:counter` and `:set` fields don't combine across replicas during a
  `where` — last-write-wins instead. That's a separate, larger gap and
  belongs in its own ADR.

## Alternatives considered

1. **Match `read_quorum`** (the original symmetric choice). Rejected
   because it's correctness-aligned only when `cluster_size == RF`. As
   the cluster grows, `read_quorum = 2` becomes increasingly lax, hiding
   records without erroring. Wrong-by-default for any non-trivial
   cluster size.
2. **No quorum check at all** (the pre-ADR behavior). Rejected. Silent
   under-representation is a real correctness bug — the caller has no
   way to know whether the empty result was empty or unavailable.
3. **A separate `:where_quorum` config knob.** Rejected as overkill. The
   correctness-derived formula is one expression; making it tunable
   invites misconfiguration without offering a use case where tuning
   helps. Can be added later if a strict-vs-lax distinction is wanted
   (e.g., analytics queries that prefer partial results).
4. **Two-phase: collect all responses, then check.** Rejected as the
   default because it offers no improvement over the chosen approach.
   Could be useful if we wanted per-record-quorum semantics ("each
   record must be confirmed by RF/2+1 of its replicas"), but that
   crosses into per-field CRDT territory and belongs in a future ADR.

## Related

- ADR-0006 — Replication factor and quorum. Defines `RF`, `W`, `R` and
  the W+R > N analysis for point reads/writes.
- ADR-0007 — Replicator excludes the owner. The asymmetry between `get`
  (querying owner + replicas) and `where` (querying every node) starts
  here.
- ADR-0017 — Routing propagation and stale-routing tolerance. The
  current live-node count this ADR's threshold depends on is itself
  shaped by routing propagation timing.
