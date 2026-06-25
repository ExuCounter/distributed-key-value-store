# ADR 0007: Replicator Excludes the Owner from the Quorum Fanout

- Status: Accepted
- Date: 2026-06-25
- Deciders: DS project
- Component: `DS.Router`, `DS.Routing`, `DS.Replicator`

## Context

`DS.put` writes locally on the owner via `DS.Storage.Primary.put`, then calls
`DS.Replicator.replicate/3` to fan the write out to replicas. The fanout list
came from `DS.Router.replica_nodes/1`, which used
`DS.Routing.replica_nodes(slot, RF)` — a ring walk that returns RF distinct
nodes starting after `slot` and wrapping around.

In a cluster of size ≥ RF, the ring walk visits every distinct node within RF
steps, including the owner (who sits at `slot` and appears at the tail of the
walk). So `Replicator.replicate/3` was sending the write to the **owner as
well as the other replicas**.

This had two concrete problems:

1. **The W quorum was degenerate.** With `write_quorum = 1`, the Replicator's
   `async_stream` waited for the first acknowledgement. The owner's own
   `GenServer.call` to itself (via `Primary.remote_write(self_node, ...)`) was
   essentially a local message round-trip, almost always the first to return.
   So `:ok` was returned the instant the owner ack'd — which it could not
   fail to do, since the local `Primary.put` had already succeeded a moment
   earlier. **Quorum was satisfied by the writer's own self-call.** No real
   replica had to confirm anything for the write to be considered durable.
2. **The owner was written twice.** Once locally via `Primary.put`, once
   remotely via `Primary.remote_write(self_node, ...)` from the fanout. The
   second write was redundant (idempotent overwrite with the same clock) but
   wasted a GenServer round-trip.

`Reader.read/1` already uses `Router.all_nodes_for/1`, which composes the
owner with `Routing.replica_nodes(slot, RF-1)`. There is no symmetric problem
on the read side.

The deeper question was: **what does `write_quorum` mean?** Two coherent
positions:

- **Position A — "owner-local is enough".** The local write is the quorum;
  `Replicator` should fire-and-forget the fanout, never block. `write_quorum`
  has no role.
- **Position B — "at least W non-owner replicas must ack".** The Replicator's
  blocking quorum is real; the owner must not count toward it.

Both are valid distributed-system designs. Position A is Dynamo-style at its
weakest. Position B gives meaningful synchronous durability.

## Decision

Adopt **Position B**. `write_quorum` means **"this many non-owner replicas
acknowledged the write before `put` returned"**. Concretely:

1. `DS.Routing.replica_nodes(slot, n)` is redefined to mean **"up to `n`
   distinct non-owner nodes following `slot` in the ring"**. The function
   looks up the slot's owner internally via `get_node/1` and excludes it from
   the result. If the slot has no owner (a brief startup window before the
   Rebalancer's first broadcast), the function returns `[]`.
2. `DS.Router.replica_nodes/1` becomes a thin wrapper:
   `Routing.replica_nodes(slot(key), RF - 1)`. The "-1" reflects that the
   owner is already counted as one of the RF copies; the function returns the
   other RF-1.
3. `DS.Replicator.replicate/3` fans out only to the result of
   `Router.replica_nodes/1`. The owner is never in this list, so the
   `write_quorum` count comes exclusively from non-owner acks.

After this change, with `RF = 3`, `W = 1`:

- Write path: owner writes locally, then waits for **1** non-owner replica to
  ack. On success, the value is durable on at least 2 nodes.
- Read path: unchanged. `Router.all_nodes_for/1` returns owner + RF-1 = 3
  distinct nodes; reader quorum `R = 2` of those must respond.
- Write set and read set are now the same 3 nodes — no asymmetry.

## Consequences

### Positive
- `write_quorum` has a meaningful semantic. With `W = 1`, writes return only
  after the data is durable on at least 2 nodes.
- No redundant self-write to the owner. One local write + RF-1 remote writes,
  not 1 + RF.
- The read set and the write set are now the same `min(cluster_size, RF)`
  nodes. The W+R analysis in ADR-0006 applies cleanly.
- The owner-exclusion lives in **one place** (`Routing.replica_nodes`) instead
  of being something every caller has to remember. New consumers of
  `replica_nodes` cannot accidentally re-introduce the bug.

### Negative
- In a cluster of fewer than RF nodes, the number of available non-owner
  replicas is `cluster_size - 1`. With `W = 1` and `cluster_size = 1`, the
  fanout is empty and the Replicator returns `{:error, :unavailable}` —
  meaning **a single-node deployment cannot perform replicated writes**. The
  local write still succeeded (`Primary.put` returned `{:ok, clock}`), but
  `DS.put` propagates the Replicator error to the caller. This is the honest
  answer: the cluster cannot meet its W requirement. A future
  `write_quorum = 0` mode could special-case "fire-and-forget" for dev or
  single-node use.
- A brief startup window exists where `Routing.replica_nodes` returns `[]`
  because the Rebalancer has not yet broadcast slot assignments. During this
  window, `Router.which_node/1` also returns `{:error, :service_unavailable}`,
  so the entire put/get path is unavailable anyway — this is consistent, not
  a new failure mode.

### Negative — what this ADR does **not** address
- Cluster tests are still needed to actually exercise the partition and
  failure scenarios that the protocol's correctness depends on.

## Alternatives considered

1. **Fire-and-forget (Position A).** Rejected as the default. Would make
   `write_quorum` vestigial and remove all synchronous durability guarantees.
   Worth offering as an explicit mode (`write_quorum = 0`) later for dev or
   for ultra-low-latency profiles, but not as the default.
2. **Keep the current behavior, document it as intentional.** Rejected.
   Including the owner in the quorum count produces a protocol that lies
   about its guarantees. No reasonable workload benefits from this.
3. **Move the owner-exclusion into `Replicator` (`replica_nodes(key) -- [node()]`).**
   Rejected. Routing decisions belong in the routing layer. Every caller of
   `replica_nodes` would otherwise have to remember to exclude the owner —
   exactly the kind of distributed footgun this codebase should avoid.
4. **Add a separate `Router.successor_nodes/1` and leave `replica_nodes`
   alone.** Rejected as redundant: there is no caller of the old
   "RF nodes including owner" semantics. Renaming or fragmenting the API for
   the sake of keeping a dead variant would just add noise.

## Related

- ADR-0006 — Replication factor and quorum. Defines `RF`, `W`, `R`. This ADR
  pins down what they mean in `Replicator`/`Reader`.
