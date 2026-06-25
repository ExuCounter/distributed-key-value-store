defmodule DS.Cluster.SanityTest do
  use DS.ClusterCase

  test "controller and peers are connected", %{peers: peers, nodes: nodes} do
    assert length(nodes) == 3
    assert node() in nodes

    for peer <- peers do
      assert peer in Node.list()
    end
  end

  test "every node has a populated routing table", %{nodes: nodes} do
    for n <- nodes do
      size =
        if n == node() do
          :ets.info(:routing, :size)
        else
          :erpc.call(n, :ets, :info, [:routing, :size])
        end

      assert size == DS.Config.slots(), "node #{inspect(n)} has #{size} slots, expected #{DS.Config.slots()}"
    end
  end

  test "schema registered on controller propagates to peers", %{peers: peers} do
    :ok = DS.Storage.Schema.register(:user, %{age: :lww, name: :lww})

    eventually(fn ->
      Enum.all?(peers, fn peer ->
        :erpc.call(peer, DS.Storage.Schema, :get, [:user]) ==
          {:ok, %{age: :lww, name: :lww}}
      end)
    end)
  end
end
