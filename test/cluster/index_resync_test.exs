defmodule DS.Cluster.IndexResyncTest do
  use DS.ClusterCase

  setup %{nodes: nodes} do
    :ok = DS.register_schema(:user, %{age: :lww, name: :lww})
    :ok = DS.create_index(:user, :age)

    eventually(fn ->
      Enum.all?(nodes, fn n -> {:user, :age} in index_pairs_on(n) end)
    end)

    :ok
  end

  test "a peer whose :indexes table was wiped recovers via the resync handler",
       %{peers: peers} do
    [peer | _] = peers

    wipe_indexes_on(peer)
    assert index_pairs_on(peer) == []

    send({DS.Storage.Index, peer}, :resync)

    eventually(fn -> {:user, :age} in index_pairs_on(peer) end)
  end

  test "after recovery, the peer holds the full forward and reverse ETS tables",
       %{peers: peers} do
    [peer | _] = peers

    wipe_indexes_on(peer)
    send({DS.Storage.Index, peer}, :resync)

    forward = DS.Storage.Index.forward_index_name(:user, :age)
    reverse = DS.Storage.Index.reverse_index_name(:user, :age)

    eventually(fn ->
      :erpc.call(peer, :ets, :info, [forward, :type]) == :ordered_set and
        :erpc.call(peer, :ets, :info, [reverse, :type]) == :set
    end)
  end

  test "resync from startup: an Index restarted on a peer rebuilds its metadata",
       %{peers: peers} do
    [peer | _] = peers

    wipe_indexes_on(peer)
    assert index_pairs_on(peer) == []

    :ok = :erpc.call(peer, Supervisor, :terminate_child, [DS.Supervisor, DS.Storage.Index])
    {:ok, _} = :erpc.call(peer, Supervisor, :restart_child, [DS.Supervisor, DS.Storage.Index])

    eventually(fn -> {:user, :age} in index_pairs_on(peer) end)
  end

  defp index_pairs_on(node) when node == node() do
    DS.Storage.Index.index_pairs()
  end

  defp index_pairs_on(node) do
    :erpc.call(node, DS.Storage.Index, :index_pairs, [])
  end

  defp wipe_indexes_on(peer) do
    pairs = :erpc.call(peer, DS.Storage.Index, :index_pairs, [])

    for {entity, field} <- pairs do
      forward = DS.Storage.Index.forward_index_name(entity, field)
      reverse = DS.Storage.Index.reverse_index_name(entity, field)

      :erpc.call(peer, :ets, :delete, [forward])
      :erpc.call(peer, :ets, :delete, [reverse])
    end

    :erpc.call(peer, :ets, :delete_all_objects, [:indexes])
  end
end
