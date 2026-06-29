defmodule DS.Cluster.HopCounterTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww})
    :ok
  end

  describe "DS.put/3" do
    test "returns :routing_inconsistent under a routing cycle", %{peers: [peer | _]} do
      poison_cycle({:user, "u1"}, node(), peer)

      assert {:error, :routing_inconsistent} = DS.put(:user, "u1", %{name: "alice"})
    end
  end

  describe "DS.tombstone/2" do
    test "returns :routing_inconsistent under a routing cycle", %{peers: [peer | _]} do
      poison_cycle({:user, "u2"}, node(), peer)

      assert {:error, :routing_inconsistent} = DS.tombstone(:user, "u2")
    end
  end

  describe "DS.do_put/4" do
    test "rejects when hops are exhausted and node is not the owner",
         %{peers: [peer | _]} do
      poison_routing({:user, "u3"}, node(), peer)

      assert {:error, :routing_inconsistent} =
               DS.do_put(:user, "u3", %{name: "carol"}, 0)
    end

    test "writes locally when hops are exhausted but node owns the slot" do
      poison_routing({:user, "u4"}, node(), node())

      assert :ok = DS.do_put(:user, "u4", %{name: "dave"}, 0)
    end
  end

  defp poison_routing(key, on_node, believed_owner) do
    slot = :erlang.phash2(key, DS.Config.slots())
    :erpc.call(on_node, :ets, :insert, [:routing, {slot, believed_owner}])
  end

  defp poison_cycle(key, node_a, node_b) do
    poison_routing(key, node_a, node_b)
    poison_routing(key, node_b, node_a)
  end
end
