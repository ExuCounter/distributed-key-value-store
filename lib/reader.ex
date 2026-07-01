defmodule DS.Reader do
  def read(primary_key) do
    case DS.Router.all_nodes_for(primary_key) do
      {:error, _} = error ->
        error

      {:ok, nodes} ->
        quorum = DS.Config.read_quorum()
        {entity, _key} = primary_key

        responses = collect_responses(nodes, primary_key, quorum)
        resolve_read(responses, entity)
    end
  end

  def pick_newer({record_a, clock_a}, {record_b, clock_b}) do
    case DS.VectorClock.compare(clock_a, clock_b) do
      :after -> {record_a, clock_a}
      :before -> {record_b, clock_b}
      _ -> deterministic_pick({record_a, clock_a}, {record_b, clock_b})
    end
  end

  def deterministic_pick({record_a, clock_a}, {record_b, clock_b}) do
    sum_a = Enum.sum(Map.values(clock_a))
    sum_b = Enum.sum(Map.values(clock_b))

    cond do
      sum_a > sum_b ->
        {record_a, clock_a}

      sum_b > sum_a ->
        {record_b, clock_b}

      true ->
        winner = (Map.keys(clock_a) ++ Map.keys(clock_b)) |> Enum.sort() |> List.first()
        if winner in Map.keys(clock_a), do: {record_a, clock_a}, else: {record_b, clock_b}
    end
  end

  defp collect_responses(nodes, primary_key, quorum) do
    DS.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      nodes,
      fn node -> DS.Storage.Primary.remote_read_raw(node, primary_key) end,
      timeout: DS.Config.replication_timeout(),
      on_timeout: :kill_task
    )
    |> Enum.reduce_while([], fn
      {:ok, {:ok, payload}}, accumulator when length(accumulator) + 1 >= quorum ->
        {:halt, [payload | accumulator]}

      {:ok, {:ok, payload}}, accumulator ->
        {:cont, [payload | accumulator]}

      _, accumulator ->
        {:cont, accumulator}
    end)
  end

  defp resolve_read([], _entity), do: {:error, :not_found}

  defp resolve_read(responses, entity) do
    if length(responses) >= DS.Config.read_quorum() do
      merged = Enum.reduce(responses, &merge_responses(&1, &2, entity))
      project(merged)
    else
      {:error, :unavailable}
    end
  end

  defp merge_responses({:tombstone, clock_a}, {:tombstone, clock_b}, _entity) do
    {:tombstone, DS.VectorClock.merge(clock_a, clock_b)}
  end

  defp merge_responses({:tombstone, tombstone_clock}, {fields, record_clock}, _entity) do
    resolve_tombstone_vs_live(fields, tombstone_clock, record_clock)
  end

  defp merge_responses({fields, record_clock}, {:tombstone, tombstone_clock}, _entity) do
    resolve_tombstone_vs_live(fields, tombstone_clock, record_clock)
  end

  defp merge_responses({fields_a, clock_a}, {fields_b, clock_b}, entity) do
    merged = DS.CRDT.merge_fields(fields_a, fields_b, entity)
    {merged, DS.VectorClock.merge(clock_a, clock_b)}
  end

  defp resolve_tombstone_vs_live(fields, tombstone_clock, record_clock) do
    case DS.VectorClock.compare(tombstone_clock, record_clock) do
      compare when compare in [:after, :equal] -> {:tombstone, tombstone_clock}
      _ -> {fields, record_clock}
    end
  end

  defp project({:tombstone, _clock}), do: {:error, :not_found}

  defp project({fields, _clock}) do
    record = Map.new(fields, fn {field, {value, _clock}} -> {field, value} end)
    {:ok, record}
  end
end
