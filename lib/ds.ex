defmodule DS do
  def register_schema(entity, schema), do: DS.Storage.Schema.register(entity, schema)
  def create_index(entity, field), do: DS.Storage.Index.create_index(entity, field)

  def get(entity, key) do
    DS.Reader.read({entity, key})
  end

  def put(entity, key, record) do
    primary_key = {entity, key}

    case DS.Router.which_node(primary_key) do
      {:error, :service_unavailable} ->
        {:error, :service_unavailable}

      {:ok, owner} when owner == node() ->
        {:ok, clock} = DS.Storage.Primary.put(primary_key, record, owner)
        DS.Replicator.replicate(primary_key, record, clock)

      {:ok, owner} ->
        forward(owner, :put, [entity, key, record])
    end
  end

  def tombstone(entity, key) do
    primary_key = {entity, key}

    case DS.Router.which_node(primary_key) do
      {:error, :service_unavailable} ->
        {:error, :service_unavailable}

      {:ok, owner} when owner == node() ->
        {:ok, clock} = DS.Storage.Primary.tombstone(primary_key, owner)
        DS.Replicator.replicate(primary_key, :tombstone, clock)

      {:ok, owner} ->
        forward(owner, :tombstone, [entity, key])
    end
  end

  def where(entity, field, min, max) do
    nodes = DS.Router.all_nodes()

    records =
      DS.TaskSupervisor
      |> Task.Supervisor.async_stream(
        nodes,
        fn node -> forward(node, :where_with_records, [entity, field, min, max]) end,
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, node_records}, acc -> merge_by_key(acc, node_records)
        _, acc -> acc
      end)
      |> Map.values()
      |> Enum.map(fn {record, _clock} -> record end)

    {:ok, records}
  end

  defp merge_by_key(acc, node_records) do
    Enum.reduce(node_records, acc, fn {key, record, clock}, map ->
      case Map.get(map, key) do
        nil -> Map.put(map, key, {record, clock})
        existing -> Map.put(map, key, pick_newer(existing, {record, clock}))
      end
    end)
  end

  defp pick_newer({rec_a, clk_a}, {rec_b, clk_b}) do
    case DS.VectorClock.compare(clk_a, clk_b) do
      :after -> {rec_a, clk_a}
      :before -> {rec_b, clk_b}
      _ -> DS.Reader.deterministic_pick({rec_a, clk_a}, {rec_b, clk_b})
    end
  end

  defp forward(node, fun, args) do
    :erpc.call(node, __MODULE__, fun, args, 5_000)
  rescue
    _ -> {:error, :node_unreachable}
  catch
    :exit, _ -> {:error, :node_unreachable}
  end
end
