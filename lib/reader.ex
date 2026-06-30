defmodule DS.Reader do
  # TODO: remote_write to stale replicas, with clock smaller

  def read(primary_key) do
    case DS.Router.all_nodes_for(primary_key) do
      {:error, _} = err ->
        err

      {:ok, nodes} ->
        quorum = DS.Config.read_quorum()

        responses =
          DS.TaskSupervisor
          |> Task.Supervisor.async_stream_nolink(
            nodes,
            fn node -> DS.Storage.Primary.remote_read(node, primary_key) end,
            timeout: DS.Config.replication_timeout(),
            on_timeout: :kill_task
          )
          |> Enum.reduce_while([], fn
            {:ok, {:ok, {record, clock}}}, accumulator
            when length(accumulator) + 1 >= quorum ->
              {:halt, [{record, clock} | accumulator]}

            {:ok, {:ok, {record, clock}}}, accumulator ->
              {:cont, [{record, clock} | accumulator]}

            _, accumulator ->
              {:cont, accumulator}
          end)

        resolve_read(responses)
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

  defp resolve_read([]), do: {:error, :not_found}

  defp resolve_read(responses) do
    if length(responses) >= DS.Config.read_quorum() do
      {record, _clock} = Enum.reduce(responses, &pick_newer/2)
      {:ok, record}
    else
      {:error, :unavailable}
    end
  end
end
