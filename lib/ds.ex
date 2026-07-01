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
        {:ok, fields} = DS.Storage.Primary.put(primary_key, record, owner)
        DS.Replicator.replicate(primary_key, fields)

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
        {:ok, tombstone_clock} = DS.Storage.Primary.tombstone(primary_key, owner)
        DS.Replicator.replicate_tombstone(primary_key, tombstone_clock)

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
    quorum = max(1, length(nodes) - DS.Config.replication_factor() + 1)

    {responded, merged} =
      DS.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        nodes,
        fn node -> forward(node, :where_with_records, [entity, field, min, max]) end,
        timeout: DS.Config.replication_timeout(),
        on_timeout: :kill_task
      )
      |> Enum.reduce({0, %{}}, fn
        {:ok, node_records}, {count, accumulator} when is_list(node_records) ->
          {count + 1, merge_by_key(accumulator, node_records, entity)}

        _, accumulator_tuple ->
          accumulator_tuple
      end)

    if responded >= quorum do
      records = merged |> Map.values() |> Enum.map(&fields_to_record/1)
      {:ok, records}
    else
      {:error, :unavailable}
    end
  end

  defp merge_by_key(accumulator, node_records, entity) do
    Enum.reduce(node_records, accumulator, fn {key, fields, _clock}, map ->
      case Map.get(map, key) do
        nil -> Map.put(map, key, fields)
        existing -> Map.put(map, key, DS.CRDT.merge_fields(existing, fields, entity))
      end
    end)
  end

  defp fields_to_record(fields) do
    Map.new(fields, fn {field, {value, _clock}} -> {field, value} end)
  end

  defp forward(node, fun, args) do
    :erpc.call(node, __MODULE__, fun, args, DS.Config.replication_timeout())
  rescue
    _ -> {:error, :node_unreachable}
  catch
    :exit, _ -> {:error, :node_unreachable}
  end
end
