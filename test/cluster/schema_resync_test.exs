defmodule DS.Cluster.SchemaResyncTest do
  use DS.ClusterCase

  setup %{nodes: nodes} do
    :ok = DS.register_schema(:user, %{name: :lww, age: :lww})

    eventually(fn ->
      Enum.all?(nodes, fn n -> schema_on(n, :user) == {:ok, %{name: :lww, age: :lww}} end)
    end)

    :ok
  end

  test "a peer whose :schemas table was wiped heals via the periodic resync",
       %{peers: [peer | _]} do
    :erpc.call(peer, :ets, :delete_all_objects, [:schemas])
    assert schema_on(peer, :user) == {:error, :not_found}

    eventually(3_000, fn -> schema_on(peer, :user) == {:ok, %{name: :lww, age: :lww}} end)
  end

  test "a Schema GenServer restarted on a peer rebuilds via handle_continue",
       %{peers: [peer | _]} do
    :erpc.call(peer, :ets, :delete_all_objects, [:schemas])
    assert schema_on(peer, :user) == {:error, :not_found}

    :ok = :erpc.call(peer, Supervisor, :terminate_child, [DS.Supervisor, DS.Storage.Schema])
    {:ok, _} = :erpc.call(peer, Supervisor, :restart_child, [DS.Supervisor, DS.Storage.Schema])

    eventually(fn -> schema_on(peer, :user) == {:ok, %{name: :lww, age: :lww}} end)
  end

  defp schema_on(node, entity) when node == node() do
    DS.Storage.Schema.get(entity)
  end

  defp schema_on(node, entity) do
    :erpc.call(node, DS.Storage.Schema, :get, [entity])
  end
end
