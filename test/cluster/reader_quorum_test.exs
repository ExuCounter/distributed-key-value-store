defmodule DS.Cluster.ReaderQuorumTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww})
    :ok
  end

  test "read quorum behavior under progressive replica loss",
       %{peers: [peer1, peer2], peer_pids: peer_pids} do
    primary_key = {:user, "rkey"}
    :ets.insert(:routing, {:erlang.phash2(primary_key, DS.Config.slots()), node()})

    :ok = DS.put(:user, "rkey", %{name: "alice"})

    assert {:ok, %{name: "alice"}} = DS.Reader.read(primary_key)

    stop_peer(peer_pids[peer1], peer1)

    assert {:ok, %{name: "alice"}} = DS.Reader.read(primary_key)

    stop_peer(peer_pids[peer2], peer2)

    assert {:error, :unavailable} = DS.Reader.read(primary_key)
  end
end
