defmodule DS.Cluster.ConflictResolutionTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww})
    :ok
  end

  test "reads converge to the deterministic winner when replicas diverge",
       %{peers: [peer1, _peer2], nodes: nodes} do
    primary_key = {:user, "split"}
    record_left = %{name: "left"}
    record_right = %{name: "right"}

    {:ok, clock_left} = DS.Storage.Primary.put(primary_key, record_left, node())

    {:ok, clock_right} =
      :erpc.call(peer1, DS.Storage.Primary, :put, [primary_key, record_right, peer1])

    {winner, _clock} =
      DS.Reader.pick_newer({record_left, clock_left}, {record_right, clock_right})

    for node <- nodes do
      assert {:ok, ^winner} = :erpc.call(node, DS, :get, [:user, "split"])
    end
  end
end
