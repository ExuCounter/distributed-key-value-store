defmodule DS.Cluster.RebalancerTest do
  use DS.ClusterCase

  setup do
    original_delay = Application.get_env(:ds, :rebalance_delay)
    Application.put_env(:ds, :rebalance_delay, 100)
    on_exit(fn -> Application.put_env(:ds, :rebalance_delay, original_delay) end)
    :ok
  end

  test "reassigns the dead peer's slots to surviving nodes",
       %{peers: [peer1, peer2], peer_pids: peer_pids} do
    assert peer1 in routing_nodes_on(node())

    stop_peer(peer_pids[peer1], peer1)

    eventually(2_000, fn ->
      peer1 not in routing_nodes_on(node()) and
        peer1 not in routing_nodes_on(peer2)
    end)

    surviving = Enum.uniq(routing_nodes_on(node()))
    assert Enum.sort(surviving) == Enum.sort([node(), peer2])
  end

  defp routing_nodes_on(node) when node == node() do
    :ets.tab2list(:routing) |> Enum.map(fn {_slot, owner} -> owner end)
  end

  defp routing_nodes_on(node) do
    :erpc.call(node, :ets, :tab2list, [:routing])
    |> Enum.map(fn {_slot, owner} -> owner end)
  end
end
