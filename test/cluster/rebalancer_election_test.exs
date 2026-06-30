defmodule DS.Cluster.RebalancerElectionTest do
  use DS.ClusterCase

  test "a new leader is elected and rebroadcasts routing when the current leader dies",
       %{peers: [peer1, _peer2]} do
    initial_leader = :global.whereis_name(:ds_rebalancer)
    assert is_pid(initial_leader)

    :erpc.call(peer1, :ets, :delete_all_objects, [:routing])
    assert :erpc.call(peer1, :ets, :info, [:routing, :size]) == 0

    :erpc.call(node(initial_leader), Process, :exit, [initial_leader, :kill])

    eventually(3_000, fn ->
      case :global.whereis_name(:ds_rebalancer) do
        :undefined -> false
        new_leader -> new_leader != initial_leader
      end
    end)

    eventually(3_000, fn ->
      :erpc.call(peer1, :ets, :info, [:routing, :size]) > 0
    end)
  end
end
