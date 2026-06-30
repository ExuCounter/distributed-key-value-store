defmodule DS.Cluster.WhereQuorumTest do
  use DS.ClusterCase

  setup %{nodes: nodes} do
    :ok = DS.register_schema(:user, %{name: :lww, age: :lww})
    :ok = DS.create_index(:user, :age)

    :ok = DS.put(:user, "u1", %{name: "alice", age: 30})
    :ok = DS.put(:user, "u2", %{name: "bob", age: 30})
    :ok = DS.put(:user, "u3", %{name: "carol", age: 30})

    eventually(fn ->
      Enum.all?(nodes, fn n ->
        {:ok, records} = :erpc.call(n, DS, :where, [:user, :age, 30, 30])
        length(records) == 3
      end)
    end)

    :ok
  end

  test "where returns the full set as long as any replica is alive (RF = cluster size)",
       %{peers: [peer1, peer2], peer_pids: peer_pids} do
    {:ok, records} = DS.where(:user, :age, 30, 30)
    assert length(records) == 3

    stop_peer(peer_pids[peer1], peer1)

    {:ok, records} = DS.where(:user, :age, 30, 30)
    assert length(records) == 3

    stop_peer(peer_pids[peer2], peer2)

    {:ok, records} = DS.where(:user, :age, 30, 30)
    assert length(records) == 3
  end
end
