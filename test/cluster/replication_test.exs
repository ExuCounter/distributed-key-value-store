defmodule DS.Cluster.ReplicationTest do
  use DS.ClusterCase

  setup do
    :ok = DS.register_schema(:user, %{name: :lww, age: :lww})
    :ok
  end

  describe "DS.put/3" do
    test "writes the record to every node in the key's replica set" do
      assert DS.put(:user, "u1", %{name: "alice"}) == :ok

      {:ok, replica_set} = DS.Router.all_nodes_for({:user, "u1"})
      assert length(replica_set) == DS.Config.replication_factor()

      eventually(fn ->
        Enum.all?(replica_set, fn n -> record_present?(n, :user, "u1", %{name: "alice"}) end)
      end)
    end

    test "subsequent puts overwrite the previous value on every replica" do
      :ok = DS.put(:user, "u1", %{name: "alice"})
      :ok = DS.put(:user, "u1", %{name: "bob"})

      {:ok, replica_set} = DS.Router.all_nodes_for({:user, "u1"})

      eventually(fn ->
        Enum.all?(replica_set, fn n -> record_present?(n, :user, "u1", %{name: "bob"}) end)
      end)
    end
  end

  describe "DS.get/2" do
    test "returns the value from any node in the cluster", %{peers: peers} do
      :ok = DS.put(:user, "u1", %{name: "alice"})

      eventually(fn ->
        DS.get(:user, "u1") == {:ok, %{name: "alice"}}
      end)

      for peer <- peers do
        eventually(fn ->
          :erpc.call(peer, DS, :get, [:user, "u1"]) == {:ok, %{name: "alice"}}
        end)
      end
    end

    test "returns :not_found for a missing key", %{peers: peers} do
      assert DS.get(:user, "ghost") == {:error, :not_found}

      for peer <- peers do
        assert :erpc.call(peer, DS, :get, [:user, "ghost"]) == {:error, :not_found}
      end
    end
  end

  defp record_present?(node, entity, key, expected_record) do
    primary_key = {entity, key}

    result =
      if node == node() do
        DS.Storage.Primary.get(primary_key)
      else
        :erpc.call(node, DS.Storage.Primary, :get, [primary_key])
      end

    case result do
      {:ok, {^expected_record, _clock}} -> true
      _ -> false
    end
  end
end
