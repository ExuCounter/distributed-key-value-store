defmodule DS.Cluster.ReplicatorQuorumTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww})
    :ok
  end

  test "write quorum behavior under progressive replica loss",
       %{peers: [peer1, peer2], peer_pids: peer_pids} do
    primary_key = {:user, "qkey"}
    pin_owner(primary_key, node())

    {:ok, fields} = DS.Storage.Primary.put(primary_key, %{name: "a"}, node())
    assert :ok = DS.Replicator.replicate(primary_key, fields)

    stop_peer(peer_pids[peer1], peer1)
    pin_owner(primary_key, node())

    {:ok, fields} = DS.Storage.Primary.put(primary_key, %{name: "b"}, node())
    assert :ok = DS.Replicator.replicate(primary_key, fields)

    stop_peer(peer_pids[peer2], peer2)
    pin_owner(primary_key, node())

    {:ok, fields} = DS.Storage.Primary.put(primary_key, %{name: "c"}, node())
    assert {:error, :unavailable} = DS.Replicator.replicate(primary_key, fields)
  end

  defp pin_owner(primary_key, owner) do
    :ets.insert(:routing, {:erlang.phash2(primary_key, DS.Config.slots()), owner})
  end
end
