# ADR 0017: Stale-Routing Tolerance via Hop Counter

- Status: Proposed
- Date: 2026-06-29
- Deciders: DS project
- Component: `DS`, `DS.Router`, `DS.Routing`, `DS.Rebalancer`

## Context

When cluster membership changes, the leader's `DS.Rebalancer` computes a new
slot → node assignment and broadcasts it to followers via `GenServer.cast`.
The cast is fire-and-forget; the only mechanism that heals a follower which
missed the cast is the periodic resync timer (currently 30 seconds).

This creates a **disagreement window**: a span of time during which different
nodes hold different routing tables. A request landing on a stale node is
forwarded to the wrong owner. What happens next depends on the receiving
node:

- `DS.put`/`DS.tombstone` re-validate ownership on arrival (they recursively
  call the public API). A single stale forwarder costs one extra erpc hop —
  no correctness issue.
- **But there is no hop counter.** If two nodes hold mutually-stale routing
  (A says B owns, B says A owns), forwarding loops until the erpc timeout
  (5s by default), tying up processes on both nodes and burning CPU on
  pointless retries.

Symmetric inconsistency happens in narrow but real scenarios:

1. **Brief broadcast window.** Leader applies the new table locally *before*
   fanning out. Between local apply and a slow follower's receipt, the
   leader and that follower disagree. The follower forwards to its
   believed-owner (the leader), the leader forwards back to the new owner
   (the follower) — loop.
2. **Leader election transition.** Old leader's last broadcast and new
   leader's first broadcast circulate concurrently; some followers see one,
   some see the other.
3. **Partition heal.** Two partitions each had a leader; tables differ at
   heal time until the next clean election.
4. **Bugs.** Defense-in-depth.

The fix needs to bound forwarding chains so a loop cannot persist. The
mechanism is independent of how propagation is delivered.

## Decision

Two changes, both small:

### 1. Hop counter on the receive side

`DS.put`/`DS.tombstone` accept an internal hop counter (default `2`). Each
forward decrements it. When the counter reaches zero and the receiving node
still does not own the slot, the call returns `{:error, :routing_inconsistent}`
instead of forwarding again.

```elixir
@max_routing_hops 2

def put(entity, key, record), do: do_put(entity, key, record, @max_routing_hops)

def do_put(entity, key, record, hops_remaining) do
  primary_key = {entity, key}

  case DS.Router.which_node(primary_key) do
    {:error, :service_unavailable} ->
      {:error, :service_unavailable}

    {:ok, owner} when owner == node() ->
      {:ok, clock} = DS.Storage.Primary.put(primary_key, record, owner)
      DS.Replicator.replicate(primary_key, record, clock)

    {:ok, _owner} when hops_remaining == 0 ->
      Logger.warning("routing inconsistent for #{inspect(primary_key)}")
      {:error, :routing_inconsistent}

    {:ok, owner} ->
      forward(owner, :do_put, [entity, key, record, hops_remaining - 1])
  end
end
```

Same pattern for `tombstone`. `get` and `where` do not forward through an
ownership chain (they fan out in parallel to known node sets), so they
don't need a hop counter.

The counter is **internal**: public callers always start at `@max_routing_hops`.
Only `forward/3` passes a decremented value.

### 2. Tighten the periodic resync interval

The disagreement window's *upper bound* in the current design is the resync
interval. At 30 seconds, a missed broadcast leaves a follower stale for
half a minute. Tighten it to **2 seconds** (`DS.Config.resync_interval`
default change). Same applies to `reconcile_interval`.

At 2s:
- Worst-case window for a missed broadcast = 2s.
- During those 2s, requests touching affected slots pay one extra erpc
  hop (~1ms LAN). In rare symmetric cases, the hop counter trips and the
  caller retries.
- After 2s, the stale follower has pulled the fresh table.

This is a one-knob change, no new mechanism.

## What is explicitly **not** done

- **No synchronous broadcast.** The leader continues to use `GenServer.cast`.
  Sync fan-out was considered and rejected: it provides no correctness
  benefit over hop counter + tightened resync, and its only meaningful
  side effect (a test-side completion signal) is better solved separately.
- **No automatic retries from the leader.** The periodic resync already
  is the retry — adding inline retries duplicates it.
- **No change to test harness propagation waits in this ADR.** That belongs
  to its own follow-up; options include telemetry events at routing apply
  or accepting the current polling helper short-term.

## Consequences

### Positive

- A request can no longer loop indefinitely between nodes with stale
  routing. Bounded to 2 hops, then a clean error.
- The disagreement-window upper bound drops from 30s to 2s purely by
  config — no new code paths, no new failure modes.
- The hop counter is dormant in healthy operation. It only does work
  during the rare moments routing is inconsistent, and even then it
  costs one extra integer argument and one extra guard clause per
  forward.
- `:routing_inconsistent` is a grep-able log signal: a steady stream
  indicates a real routing or broadcast bug worth investigating.

### Negative

- Background traffic increases modestly: each node now resyncs every 2s
  instead of every 30s. The resync is a cheap GenServer call to a peer
  fetching `:routing`/`:schemas`/`:indexes` (a few hundred entries at
  most). Acceptable.
- A request that hits the hop-counter trip returns
  `{:error, :routing_inconsistent}` and must be retried by the caller.
  Callers already handle `{:error, :node_unreachable}` and similar; this
  is one more error tuple in the same family.

### Negative — what this ADR does **not** address

- The Rebalancer leader election protocol itself. If the leader dies
  mid-broadcast, recovery latency is bounded by election timing plus the
  2s resync interval; both are separate concerns.
- Slot handoff (moving primary records when ownership changes). Routing
  propagates fast; the records still live on the old owner until anti-
  entropy moves them. Future ADR.
- Schema/Index propagation correctness during partition. Same gossip +
  periodic resync model; the hop counter doesn't apply because there's
  no forwarding chain.

## Alternatives considered

1. **Sync fan-out for routing broadcast.** Rejected. Provides no
   correctness benefit beyond what the hop counter already gives. Its
   "shorter disagreement window" argument collapses on inspection: in the
   failure case (follower didn't apply), sync without retry has the same
   recovery window as async (both rely on periodic resync). In the
   happy case, the windows are within milliseconds of each other. The
   only concrete sync benefit is a test-side signal, which is better
   addressed by telemetry in a separate change.
2. **Sync fan-out plus explicit retries.** Rejected. Duplicates the
   periodic resync's job. Adding a third propagation mechanism (cast,
   retry, resync) for marginal window shrinkage is not worth the
   complexity.
3. **Two-phase commit on routing.** Rejected as overkill. Routing is
   eventually consistent by design. The hop counter handles in-flight
   requests; the tightened resync handles healing.
4. **Trust forwarder, write locally on misroute.** Rejected. Trades a
   small latency win for a real correctness hole (split-brain during
   routing churn).
5. **Reject all misroutes, no forwarding.** Rejected as the default;
   adopted only as the fallback after the hop counter is exhausted.
   Re-validate-and-forward handles the common single-stale-node case
   without bothering the caller.

## Related

- ADR-0006 — Replication factor and quorum.
- ADR-0007 — Replicator excludes owner from fanout.
- ADR-0013 — Index sync (peer-to-peer, push-on-event + periodic pull).
- ADR-0016 — Cluster suite owns controller lifecycle.
