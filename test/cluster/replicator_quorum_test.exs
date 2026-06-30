defmodule DS.Cluster.ReplicatorQuorumTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww})
    :ok
  end

  test "write quorum behavior under progressive replica loss",
       %{peers: [peer1, peer2], peer_pids: peer_pids} do
    primary_key = {:user, "qkey"}
    :ets.insert(:routing, {:erlang.phash2(primary_key, DS.Config.slots()), node()})

    {:ok, clock} = DS.Storage.Primary.put(primary_key, %{name: "a"}, node())
    assert :ok = DS.Replicator.replicate(primary_key, %{name: "a"}, clock)

    stop_peer(peer_pids[peer1], peer1)

    {:ok, clock} = DS.Storage.Primary.put(primary_key, %{name: "b"}, node())
    assert :ok = DS.Replicator.replicate(primary_key, %{name: "b"}, clock)

    stop_peer(peer_pids[peer2], peer2)

    {:ok, clock} = DS.Storage.Primary.put(primary_key, %{name: "c"}, node())
    assert {:error, :unavailable} = DS.Replicator.replicate(primary_key, %{name: "c"}, clock)
  end
end
