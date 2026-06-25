defmodule DS.Cluster.IndexSyncTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{age: :lww, name: :lww})
    :ok
  end

  test "create_index propagates to every peer", %{nodes: nodes} do
    :ok = DS.create_index(:user, :age)

    eventually(fn ->
      Enum.all?(nodes, fn n -> {:user, :age} in index_pairs_on(n) end)
    end)
  end

  test "the same index is registered on every peer with both forward and reverse tables",
       %{nodes: nodes} do
    :ok = DS.create_index(:user, :age)

    forward = DS.Storage.Index.forward_index_name(:user, :age)
    reverse = DS.Storage.Index.reverse_index_name(:user, :age)

    eventually(fn ->
      Enum.all?(nodes, fn n ->
        :erpc.call(n, :ets, :info, [forward, :type]) == :ordered_set and
          :erpc.call(n, :ets, :info, [reverse, :type]) == :set
      end)
    end)
  end

  defp index_pairs_on(node) when node == node() do
    DS.Storage.Index.index_pairs()
  end

  defp index_pairs_on(node) do
    :erpc.call(node, DS.Storage.Index, :index_pairs, [])
  end
end
