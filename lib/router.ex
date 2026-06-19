defmodule DS.Router do
  @slots 1024
  @replication_factor 3

  def which_node(key) do
    slot = slot(key)
    DS.Routing.get_node(slot)
  end

  def replica_nodes(key), do: DS.Routing.replica_nodes(slot(key), @replication_factor)

  def all_nodes_for(key) do
    slot = slot(key)

    case DS.Routing.get_node(slot) do
      {:ok, owner} ->
        replicas = DS.Routing.replica_nodes(slot, @replication_factor - 1)
        {:ok, Enum.uniq([owner | replicas])}

      {:error, error} ->
        {:error, error}
    end
  end

  def all_nodes() do
    [node() | Node.list()]
  end

  defp slot(key), do: :erlang.phash2(key, @slots)
end
