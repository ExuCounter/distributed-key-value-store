defmodule DS.RouterTest do
  use ExUnit.Case, async: false

  alias DS.Router
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

  defp populate_all_slots(node) do
    assignments = for slot <- 0..(DS.Config.slots() - 1), do: {slot, node}
    :ok = Routing.bulk_update(assignments)
  end

  defp populate_round_robin(nodes) do
    nodes_tuple = List.to_tuple(nodes)
    count = tuple_size(nodes_tuple)

    assignments =
      for slot <- 0..(DS.Config.slots() - 1) do
        {slot, elem(nodes_tuple, rem(slot, count))}
      end

    :ok = Routing.bulk_update(assignments)
  end

  describe "which_node/1" do
    test "returns the node owning the slot for the given key" do
      populate_all_slots(:node_a)
      assert Router.which_node("anything") == {:ok, :node_a}
      assert Router.which_node({:user, "u1"}) == {:ok, :node_a}
      assert Router.which_node(42) == {:ok, :node_a}
    end

    test "returns :service_unavailable when the routing table is empty" do
      assert Router.which_node("anything") == {:error, :service_unavailable}
    end

    test "is deterministic for the same key" do
      populate_round_robin([:a, :b, :c])
      first = Router.which_node("stable_key")

      for _ <- 1..5 do
        assert Router.which_node("stable_key") == first
      end
    end
  end

  describe "replica_nodes/1" do
    test "returns replication_factor unique nodes when enough are available" do
      populate_round_robin([:a, :b, :c, :d])

      result = Router.replica_nodes("k1")

      assert length(result) == DS.Config.replication_factor()
      assert length(Enum.uniq(result)) == DS.Config.replication_factor()
      assert Enum.all?(result, &(&1 in [:a, :b, :c, :d]))
    end

    test "returns fewer than replication_factor when not enough distinct nodes exist" do
      populate_all_slots(:only_node)

      assert Router.replica_nodes("k1") == [:only_node]
    end

    test "returns [] when the routing table is empty" do
      assert Router.replica_nodes("k1") == []
    end

    test "is deterministic for the same key" do
      populate_round_robin([:a, :b, :c])
      first = Router.replica_nodes("stable_key")

      for _ <- 1..5 do
        assert Router.replica_nodes("stable_key") == first
      end
    end
  end

  describe "all_nodes_for/1" do
    test "returns owner followed by replicas, all unique" do
      populate_round_robin([:a, :b, :c, :d])

      assert {:ok, nodes} = Router.all_nodes_for("k1")

      assert length(nodes) == DS.Config.replication_factor()
      assert length(Enum.uniq(nodes)) == DS.Config.replication_factor()
    end

    test "deduplicates when owner reappears among the successor sweep" do
      populate_all_slots(:only_node)

      assert Router.all_nodes_for("k1") == {:ok, [:only_node]}
    end

    test "returns the routing error when the slot has no assignment" do
      assert Router.all_nodes_for("k1") == {:error, :service_unavailable}
    end

    test "first element is always the slot owner" do
      populate_round_robin([:a, :b, :c, :d])

      {:ok, owner_first_list} = Router.all_nodes_for("k1")
      {:ok, owner} = Router.which_node("k1")

      assert hd(owner_first_list) == owner
    end
  end

  describe "all_nodes/0" do
    test "returns at least the local node" do
      assert node() in Router.all_nodes()
    end

    test "with no connected peers, returns exactly [node()]" do
      # libcluster's epmd strategy can't reach the configured fake nodes in
      # tests, so Node.list/0 is empty here.
      assert Router.all_nodes() == [node()]
    end
  end
end
