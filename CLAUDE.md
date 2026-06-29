Architectural rationale lives in `docs/adrs/`. Read the relevant ADR before
proposing changes in a touched area.

## Style

- **No abbreviated identifiers.** Spell domain names out: `clock` not `clk`,
  `record` not `rec`, `accumulator` not `acc`. Loop variables `i`/`n` are
  fine in pure numeric contexts.
- **No explanatory comments above functions** — what they do, why, ADR
  references. Code should speak for itself; rationale lives in ADRs.
  Comments only for non-obvious invariants or workarounds.
- **Tests assert exact values via the public API**, not existence checks like
  `!= :undefined`. Drive a follow-up read through the real API and assert on
  the returned value.

## Cluster state propagation

- **Schema, Index, Routing are sharded by metadata-vs-data**:
  - Schema and Index ship only **metadata** between nodes (which entities,
    which `(entity, field)` pairs). Contents are derived from local
    `:primary` via `Primary.put`'s `update_indexes` side effect.
  - Routing is broadcast by the leader Rebalancer; followers passively
    apply.
  - **Never sync primary records across nodes wholesale.** Each node holds
    only the slots it owns or replicates. Bulk-shipping `:primary` defeats
    sharding.

- **Propagation is push-on-event + periodic pull**. A node that joins late
  and misses a cast recovers via the periodic resync. Don't reach for
  imperative "ensure sync now" calls in production paths.

- **`Routing.replica_nodes(slot, n)` excludes the owner internally** and
  returns `[]` for unowned slots. Callers don't filter, don't subtract
  owners, don't check slot ownership themselves.

## Replication and quorum (ADR-0006, ADR-0007)

- `RF = 3`, `W = 1` (one non-owner ack), `R = 2`.
- Effective `W = 1 (local owner) + write_quorum = 2`. With `R = 2`,
  `W_e + R = 4 > N = 3` → strict overlap, no stale-read window.
- **`Replicator.replicate/3` fans out to non-owner replicas only**. The
  owner's local `Primary.put` already happened before `replicate` is
  called. Including the owner in the quorum count makes `W` meaningless.
- `DS.where/4` fans out to **every node** via
  `forward(node, :where_with_records, ...)`. The MFA target `:erpc.call`
  uses is `DS` (not `DS.Storage.Index`), so `DS.where_with_records/4`
  exists as a thin delegate. Don't remove it.

## Cluster test harness (ADR-0015, ADR-0016)

- Located at `test/support/cluster_case.ex`. Each cluster test module does
  `use DS.ClusterCase` — gives a 3-node cluster (controller + 2 peers).
- **`prevent_overlapping_partitions` is disabled in test env**
  (`test_helper.exs`) — `:global`'s partition detector treats deterministic
  peer churn as a real partition and forces disconnects. False positive in
  tests; safety net stays on in production.
- **Per-suite stop/start of the DS app on the controller** to clear
  `:global` registrations and any pending Rebalancer timers. `on_exit`
  also stops the app so the next test (cluster or isolated) starts clean.
- **`Application.stop/1` returns before children are fully torn down** in
  tight stop/start cycles. A small `Process.alive?` polling loop in
  `stop_ds_synchronously` is acceptable — this is test infrastructure
  bridging an OTP timing quirk, not test-assertion polling.

## Test-assertion style

- **Isolated tests start their own GenServers** via the
  `case Module.start_link([]) do {:ok, _} -> :ok;
  {:error, {:already_started, _}} -> :ok end` pattern. They don't depend on
  the DS app being currently running on the controller.
- **`eventually/2` is OK for application-level state convergence** (writes
  propagating to replicas, schema/index casts arriving on peers). The
  long-term direction is `:telemetry` events emitted at propagation
  points so tests can `assert_receive` instead, but this hasn't been
  built yet.
- **Node lifecycle waits use `:net_kernel.monitor_nodes` + `receive`,
  not polling.** See `stop_peer_node/1`.

## Don't do these

- **Don't call `:ets.tab2list(:indexes)` (or any named DS ETS table)
  without first verifying the table exists** in test helpers. If the
  DS app is stopped, the table is gone.
- **Don't reuse peer node names across test suites.** Use
  `:erlang.unique_integer/1` suffixes (see `DS.ClusterCase`). `:global`
  gets confused otherwise.
- **Don't introduce defensive `if not nil` guards** unless there's a real
  scenario producing nil. Trust internal code; validate at boundaries.
- **Don't paste ADR rationale into code comments.** Reference the ADR in
  the commit message instead.

## Bugs already fixed in this codebase — don't reintroduce

- Forward-index row was `{value, key}` on `:ordered_set` — collided on the
  value key for records sharing the same indexed value. Now
  `{{value, key}, key}` with composite key.
- `Replicator.replicate/3` used to include the owner in fanout, making
  `W = 1` trivially satisfied by the owner's self-write.
- `Rebalancer.rebalance/1` used to broadcast to `Node.list()` only,
  never updating the leader's own routing table.
- `DS.where/4` used to call `forward(node, :where_with_records, ...)`
  with no `DS.where_with_records/4` delegate — every cluster query
  silently returned `[]`.
- Schema syncs at startup + periodically; Index now does the same.
  Before, a node joining after `create_index/2` silently full-scanned
  every `where/4` query.
