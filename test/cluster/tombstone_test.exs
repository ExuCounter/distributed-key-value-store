defmodule DS.Cluster.TombstoneTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww, age: :lww})
    :ok = DS.create_index(:user, :age)
    :ok
  end

  describe "DS.tombstone/2" do
    test "propagates to every replica", %{nodes: nodes} do
      :ok = DS.put(:user, "u1", %{name: "alice", age: 30})

      eventually(fn ->
        Enum.all?(nodes, fn n -> get_on(n, :user, "u1") == {:ok, %{name: "alice", age: 30}} end)
      end)

      :ok = DS.tombstone(:user, "u1")

      eventually(fn ->
        Enum.all?(nodes, fn n -> get_on(n, :user, "u1") == {:error, :not_found} end)
      end)
    end

    test "is idempotent" do
      :ok = DS.put(:user, "u2", %{name: "bob", age: 25})

      assert :ok = DS.tombstone(:user, "u2")
      assert :ok = DS.tombstone(:user, "u2")
      assert DS.get(:user, "u2") == {:error, :not_found}
    end

    test "works on a key that was never written" do
      assert :ok = DS.tombstone(:user, "ghost")
      assert DS.get(:user, "ghost") == {:error, :not_found}
    end

    test "removes the key from indexes on every replica", %{nodes: nodes} do
      :ok = DS.put(:user, "u3", %{name: "carol", age: 42})

      eventually(fn ->
        Enum.all?(nodes, fn n -> "u3" in index_keys_on(n, :user, :age, 42, 42) end)
      end)

      :ok = DS.tombstone(:user, "u3")

      eventually(fn ->
        Enum.all?(nodes, fn n -> "u3" not in index_keys_on(n, :user, :age, 42, 42) end)
      end)
    end

    test "a subsequent put resurrects the key on every replica", %{nodes: nodes} do
      :ok = DS.put(:user, "u4", %{name: "dave", age: 50})
      :ok = DS.tombstone(:user, "u4")
      :ok = DS.put(:user, "u4", %{name: "dave-reborn", age: 51})

      eventually(fn ->
        Enum.all?(nodes, fn n ->
          get_on(n, :user, "u4") == {:ok, %{name: "dave-reborn", age: 51}}
        end)
      end)
    end
  end

  defp get_on(node, entity, key) when node == node(), do: DS.get(entity, key)
  defp get_on(node, entity, key), do: :erpc.call(node, DS, :get, [entity, key])

  defp index_keys_on(node, entity, field, min, max) when node == node() do
    DS.Storage.Index.where(entity, field, min, max)
  end

  defp index_keys_on(node, entity, field, min, max) do
    :erpc.call(node, DS.Storage.Index, :where, [entity, field, min, max])
  end
end
