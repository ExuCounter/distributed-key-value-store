defmodule DS.Cluster.ConflictResolutionTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww})
    :ok
  end

  test "reads converge to the deterministic merge when replicas diverge",
       %{peers: [peer1, _peer2], nodes: nodes} do
    primary_key = {:user, "split"}

    {:ok, fields_left} = DS.Storage.Primary.put(primary_key, %{name: "left"}, node())

    {:ok, fields_right} =
      :erpc.call(peer1, DS.Storage.Primary, :put, [primary_key, %{name: "right"}, peer1])

    merged = DS.CRDT.merge_fields(fields_left, fields_right, :user)
    expected = Map.new(merged, fn {field, {value, _clock}} -> {field, value} end)

    for node <- nodes do
      assert {:ok, ^expected} = :erpc.call(node, DS, :get, [:user, "split"])
    end
  end
end
