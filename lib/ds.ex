defmodule DS do
  require Logger

  @max_routing_hops 2

  def register_schema(entity, schema), do: DS.Storage.Schema.register(entity, schema)
  def create_index(entity, field), do: DS.Storage.Index.create_index(entity, field)

  def get(entity, key) do
    DS.Reader.read({entity, key})
  end

  def put(entity, key, record), do: do_put(entity, key, record, @max_routing_hops)

  def do_put(entity, key, record, hops_remaining) do
    primary_key = {entity, key}

    case DS.Router.which_node(primary_key) do
      {:error, :service_unavailable} ->
        {:error, :service_unavailable}

      {:ok, owner} when owner == node() ->
        {:ok, clock} = DS.Storage.Primary.put(primary_key, record, owner)
        DS.Replicator.replicate(primary_key, record, clock)

      {:ok, _owner} when hops_remaining == 0 ->
        Logger.warning("routing inconsistent for #{inspect(primary_key)}")
        {:error, :routing_inconsistent}

      {:ok, owner} ->
        forward(owner, :do_put, [entity, key, record, hops_remaining - 1])
    end
  end

  def tombstone(entity, key), do: do_tombstone(entity, key, @max_routing_hops)

  def do_tombstone(entity, key, hops_remaining) do
    primary_key = {entity, key}

    case DS.Router.which_node(primary_key) do
      {:error, :service_unavailable} ->
        {:error, :service_unavailable}

      {:ok, owner} when owner == node() ->
        {:ok, clock} = DS.Storage.Primary.tombstone(primary_key, owner)
        DS.Replicator.replicate(primary_key, :tombstone, clock)

      {:ok, _owner} when hops_remaining == 0 ->
        Logger.warning("routing inconsistent for #{inspect(primary_key)}")
        {:error, :routing_inconsistent}

      {:ok, owner} ->
        forward(owner, :do_tombstone, [entity, key, hops_remaining - 1])
    end
  end

  def where_with_records(entity, field, min, max) do
    DS.Storage.Index.where_with_records(entity, field, min, max)
  end

  def where(entity, field, min, max) do
    nodes = DS.Router.all_nodes()

    records =
      DS.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        nodes,
        fn node -> forward(node, :where_with_records, [entity, field, min, max]) end,
        timeout: DS.Config.replication_timeout(),
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, node_records}, accumulator -> merge_by_key(accumulator, node_records)
        _, accumulator -> accumulator
      end)
      |> Map.values()
      |> Enum.map(fn {record, _clock} -> record end)

    {:ok, records}
  end

  defp merge_by_key(accumulator, node_records) do
    Enum.reduce(node_records, accumulator, fn {key, record, clock}, map ->
      case Map.get(map, key) do
        nil -> Map.put(map, key, {record, clock})
        existing -> Map.put(map, key, DS.Reader.pick_newer(existing, {record, clock}))
      end
    end)
  end

  defp forward(node, fun, args) do
    :erpc.call(node, __MODULE__, fun, args, DS.Config.replication_timeout())
  rescue
    _ -> {:error, :node_unreachable}
  catch
    :exit, _ -> {:error, :node_unreachable}
  end
end
