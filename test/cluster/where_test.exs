defmodule DS.Cluster.WhereTest do
  use DS.ClusterCase

  setup %{nodes: nodes} do
    :ok = DS.register_schema(:user, %{age: :lww, name: :lww})
    :ok = DS.create_index(:user, :age)

    eventually(fn ->
      Enum.all?(nodes, fn n -> {:user, :age} in index_pairs_on(n) end)
    end)

    :ok
  end

  test "returns records whose indexed value falls in [min, max]" do
    :ok = DS.put(:user, "u1", %{name: "alice", age: 25})
    :ok = DS.put(:user, "u2", %{name: "bob", age: 35})
    :ok = DS.put(:user, "u3", %{name: "carol", age: 50})

    eventually(fn ->
      case DS.where(:user, :age, 30, 40) do
        {:ok, records} -> Enum.sort(records) == [%{name: "bob", age: 35}]
        _ -> false
      end
    end)
  end

  test "returns every matching record from across the cluster, deduplicated by key" do
    :ok = DS.put(:user, "u1", %{name: "alice", age: 25})
    :ok = DS.put(:user, "u2", %{name: "bob", age: 35})
    :ok = DS.put(:user, "u3", %{name: "carol", age: 50})

    eventually(fn ->
      case DS.where(:user, :age, :negative_infinity, :infinity) do
        {:ok, records} ->
          Enum.sort_by(records, & &1.age) ==
            [
              %{name: "alice", age: 25},
              %{name: "bob", age: 35},
              %{name: "carol", age: 50}
            ]

        _ ->
          false
      end
    end)
  end

  test "returns an empty list when no records match the range" do
    :ok = DS.put(:user, "u1", %{name: "alice", age: 25})

    eventually(fn ->
      case DS.where(:user, :age, 100, 200) do
        {:ok, []} -> true
        _ -> false
      end
    end)
  end

  test "is callable from any peer and returns the same result", %{peers: peers} do
    :ok = DS.put(:user, "u1", %{name: "alice", age: 25})
    :ok = DS.put(:user, "u2", %{name: "bob", age: 35})

    expected_records = [%{name: "alice", age: 25}, %{name: "bob", age: 35}]

    for peer <- peers do
      eventually(fn ->
        case :erpc.call(peer, DS, :where, [:user, :age, :negative_infinity, :infinity]) do
          {:ok, records} -> Enum.sort_by(records, & &1.age) == expected_records
          _ -> false
        end
      end)
    end
  end

  defp index_pairs_on(node) when node == node() do
    DS.Storage.Index.index_pairs()
  end

  defp index_pairs_on(node) do
    :erpc.call(node, DS.Storage.Index, :index_pairs, [])
  end
end
