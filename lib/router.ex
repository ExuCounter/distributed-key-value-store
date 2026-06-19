defmodule DS.Router do
  def which_node(key) do
    slot = slot(key)
    DS.Routing.get_node(slot)
  end

  def replica_nodes(key), do: DS.Routing.replica_nodes(slot(key), DS.Config.replication_factor())

  def all_nodes_for(key) do
    slot = slot(key)

    case DS.Routing.get_node(slot) do
      {:ok, owner} ->
        replicas = DS.Routing.replica_nodes(slot, DS.Config.replication_factor() - 1)
        {:ok, Enum.uniq([owner | replicas])}

      {:error, error} ->
        {:error, error}
    end
  end

  def all_nodes() do
    [node() | Node.list()]
  end

  defp slot(key), do: :erlang.phash2(key, DS.Config.slots())
end
