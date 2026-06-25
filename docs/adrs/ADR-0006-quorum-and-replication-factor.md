# ADR 0006: Replication Factor and Quorum

- Status: Accepted
- Date: 2026-06-25
- Deciders: DS project
- Component: `DS.Replicator`, `DS.Reader`, `DS.Router`, `DS.Config`

## Context

The store replicates each key to multiple nodes for availability and durability.
Two parameters govern the read/write protocol:

- **Replication factor (RF)** — how many nodes hold a copy of each key.
- **Write quorum (W)** and **read quorum (R)** — how many of those copies must
  acknowledge a write, and how many must respond to a read, before the
  operation is considered successful.

The standard relationship `W + R > N` (where N is the replica count involved
in the protocol) guarantees that the read set and the write set always
overlap, so a read after a successful write sees at least one node that has
the new value. The choice between `W + R > N` and weaker forms is a direct
trade-off between write latency, read latency, and consistency.

In this system, the owner of a slot always writes locally first (via
`DS.Storage.Primary.put`) before `DS.Replicator.replicate/3` fans out to
non-owner replicas (ADR-0007). So the **effective number of nodes that hold
the new value when `put` returns** is `1 + write_quorum` — one local write,
plus the configured number of non-owner acks. The W+R analysis below uses
`W_effective = 1 + write_quorum`.

For a 3-node deployment, the natural choices are:

| Profile | RF | W (non-owner) | W_effective | R | Property |
|---|---|---|---|---|---|
| Fast writes, eventual consistency | 3 | 0 | 1 | 1 | W_e+R = 2 < N → no guarantee |
| **Strong reads, fast writes** | **3** | **1** | **2** | **2** | **W_e+R = 4 > N → strict overlap** |
| Maximum durability | 3 | 2 | 3 | 2 | W_e+R = 5 > N → strict overlap, slow writes |

This system targets **low-latency writes** (every `put` returns as soon as one
non-owner replica acknowledges, on top of the local owner write) and
**strong read-your-writes** (the W_e+R > N relationship guarantees that any
read quorum response set overlaps with the write set).

## Decision

- `replication_factor = 3`
- `write_quorum = 1` (one non-owner ack; `W_effective = 2` including the
  owner's local write)
- `read_quorum = 2`

These are configured via `DS.Config` (see ADR-0010), defaulting in
`config/config.exs`. The semantic of `write_quorum` is defined in ADR-0007.

## Consequences

### Positive
- `W_effective + R = 4 > N = 3` → strict overlap. Any successful read quorum
  intersects the write set on at least one node, so reads see the freshest
  written value via `Reader.resolve_read`'s vector-clock comparison.
- Writes return after one local write + one non-owner ack — fast in the
  common case, durable on at least 2 nodes.
- The system stays available for writes as long as the owner is reachable
  **and** at least one non-owner replica is reachable.

### Negative
- Writes require both the owner and at least one non-owner replica. A
  partition isolating the owner from every other replica fails writes
  (`{:error, :unavailable}` from `Replicator`) even though the local
  `Primary.put` succeeded — the caller sees the failure, but the local store
  holds the data anyway. See ADR-0007 for the rationale.
- Reads require any 2 of `RF=3` nodes to respond. If only 1 is reachable,
  reads fail with `{:error, :unavailable}` rather than returning a possibly
  stale single response.
- The choice is wired into multiple modules (`Replicator`, `Reader`,
  `Router.all_nodes_for`); changing it requires aligning all of them.

## Alternatives considered

1. **W=2, R=2 (`W_e + R = 5 > N`).** Rejected for now. Stronger durability
   (data on all RF nodes before `put` returns) at the cost of write latency
   (wait for both non-owner replicas) and availability (any non-owner replica
   down blocks writes). May be revisited if the workload demands maximum
   durability per write.
2. **W=1, R=3.** Rejected. Read latency depends on the slowest of all three
   nodes; a single slow replica blocks every read. R should not require every
   node.
3. **W=0, R=2 (fire-and-forget writes).** Rejected as default but reasonable
   as an opt-in mode. With `write_quorum = 0`, `Replicator` would fire the
   fanout without waiting; `put` returns after the local owner write. Loses
   the read-your-writes guarantee (`W_e + R = 3 = N`) but unblocks
   single-node deployments where there is no non-owner replica to ack. Worth
   adding as a configurable mode later.
4. **W=1, R=1.** Rejected. R=1 gives whichever replica answers first,
   regardless of freshness. With `W_e + R = 3 = N` and no read-side
   reconciliation across multiple responses, individual reads become
   unpredictable. Not worth the latency savings for this workload.
5. **Tunable per-call quorums.** Rejected for v1. Cassandra-style
   per-operation `:quorum` / `:one` / `:all` adds API surface and operational
   complexity without a current use case. Defer.

## Related

- ADR-0007 — Replicator excludes the owner from the quorum fanout. Pins down
  what "an ack" counts for in the W=1 quorum (non-owner replicas only).
- ADR-0010 — Runtime configuration via `Application.get_env`.
