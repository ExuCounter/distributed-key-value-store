defmodule DS.Cluster.PerFieldMergeTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww, age: :lww})
    :ok
  end

  test "concurrent writes to different fields both survive the merge",
       %{peers: [peer1, _peer2], nodes: nodes} do
    primary_key = {:user, "u1"}

    {:ok, _} = DS.Storage.Primary.put(primary_key, %{name: "alice"}, node())
    {:ok, _} = :erpc.call(peer1, DS.Storage.Primary, :put, [primary_key, %{age: 30}, peer1])

    expected = %{name: "alice", age: 30}

    for node <- nodes do
      assert {:ok, ^expected} = :erpc.call(node, DS, :get, [:user, "u1"])
    end
  end
end
