defmodule DS.RoutingTest do
  use ExUnit.Case, async: false

  alias DS.Routing

  setup_all do
    case Routing.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    :ets.delete_all_objects(:routing)
    :ok
  end

  describe "put_slot/2 and get_node/1" do
    test "round-trips a slot to its node" do
      :ok = Routing.put_slot(1, :node_a)
      assert Routing.get_node(1) == {:ok, :node_a}
    end

    test "missing slot returns :service_unavailable" do
      assert Routing.get_node(42) == {:error, :service_unavailable}
    end

    test "put_slot overwrites an existing assignment" do
      :ok = Routing.put_slot(1, :node_a)
      :ok = Routing.put_slot(1, :node_b)
      assert Routing.get_node(1) == {:ok, :node_b}
    end
  end

  describe "bulk_update/1" do
    test "inserts multiple slot assignments at once" do
      :ok = Routing.bulk_update([{1, :a}, {2, :b}, {3, :c}])

      assert Routing.get_node(1) == {:ok, :a}
      assert Routing.get_node(2) == {:ok, :b}
      assert Routing.get_node(3) == {:ok, :c}
    end

    test "empty list is a no-op" do
      :ok = Routing.bulk_update([])
      assert Routing.all_slots() == []
    end

    test "overwrites previously assigned slots" do
      :ok = Routing.put_slot(1, :a)
      :ok = Routing.bulk_update([{1, :z}, {2, :b}])

      assert Routing.get_node(1) == {:ok, :z}
      assert Routing.get_node(2) == {:ok, :b}
    end
  end

  describe "all_slots/0" do
    test "returns an empty list with no assignments" do
      assert Routing.all_slots() == []
    end

    test "returns every slot/node pair" do
      :ok = Routing.bulk_update([{1, :a}, {2, :b}])
      assert Enum.sort(Routing.all_slots()) == [{1, :a}, {2, :b}]
    end
  end

  describe "replica_nodes/2" do
    test "returns n unique nodes walking the ring from the given slot" do
      :ok = Routing.bulk_update([{10, :a}, {20, :b}, {30, :c}, {40, :d}])

      assert Routing.replica_nodes(15, 3) == [:b, :c, :d]
    end

    test "wraps around past the highest slot" do
      :ok = Routing.bulk_update([{10, :a}, {20, :b}, {30, :c}])

      assert Routing.replica_nodes(25, 3) == [:c, :a, :b]
    end

    test "starts from the matching slot when the key equals a slot" do
      :ok = Routing.bulk_update([{10, :a}, {20, :b}, {30, :c}])

      assert Routing.replica_nodes(20, 2) == [:c, :a]
    end

    test "deduplicates nodes that own multiple consecutive slots" do
      :ok = Routing.bulk_update([{10, :a}, {20, :a}, {30, :b}, {40, :c}])

      assert Routing.replica_nodes(5, 3) == [:a, :b, :c]
    end

    test "fewer than n unique nodes available returns all of them (less than quorum)" do
      :ok = Routing.bulk_update([{10, :a}, {20, :b}])

      result = Routing.replica_nodes(0, 5)
      assert length(result) == 2
      assert Enum.sort(result) == [:a, :b]
    end

    test "slot not in ring still produces correct successor list" do
      :ok = Routing.bulk_update([{10, :a}, {30, :b}, {50, :c}])

      assert Routing.replica_nodes(25, 2) == [:b, :c]
      assert Routing.replica_nodes(100, 2) == [:a, :b]
    end

    test "empty ring returns an empty list" do
      assert Routing.replica_nodes(1, 3) == []
    end

    test "n = 0 returns an empty list" do
      :ok = Routing.bulk_update([{10, :a}, {20, :b}])
      assert Routing.replica_nodes(5, 0) == []
    end
  end
end
