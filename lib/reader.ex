defmodule DS.Reader do
  @quorum 2

  # TODO: remote_write to stale replicas, with clock smaller

  def read(primary_key) do
    case DS.Router.all_nodes_for(primary_key) do
      {:error, _} = err ->
        err

      {:ok, nodes} ->
        responses =
          DS.TaskSupervisor
          |> Task.Supervisor.async_stream(
            nodes,
            fn node -> DS.Storage.Primary.remote_read(node, primary_key) end,
            timeout: 5_000,
            on_timeout: :kill_task
          )
          |> Enum.reduce_while([], fn
            {:ok, {:ok, {record, clock}}}, acc when length(acc) + 1 >= @quorum ->
              {:halt, [{record, clock} | acc]}

            {:ok, {:ok, {record, clock}}}, acc ->
              {:cont, [{record, clock} | acc]}

            _, acc ->
              {:cont, acc}
          end)

        resolve_read(responses)
    end
  end

  def deterministic_pick({rec_a, clk_a}, {rec_b, clk_b}) do
    sum_a = Enum.sum(Map.values(clk_a))
    sum_b = Enum.sum(Map.values(clk_b))

    cond do
      sum_a > sum_b ->
        {rec_a, clk_a}

      sum_b > sum_a ->
        {rec_b, clk_b}

      true ->
        winner = (Map.keys(clk_a) ++ Map.keys(clk_b)) |> Enum.sort() |> List.first()
        if winner in Map.keys(clk_a), do: {rec_a, clk_a}, else: {rec_b, clk_b}
    end
  end

  defp resolve_read([]), do: {:error, :not_found}

  defp resolve_read(responses) when length(responses) >= @quorum do
    {record, _clock} =
      Enum.reduce(responses, fn {rec, clk}, {acc_rec, acc_clk} ->
        case DS.VectorClock.compare(clk, acc_clk) do
          :after -> {rec, clk}
          :before -> {acc_rec, acc_clk}
          _ -> deterministic_pick({rec, clk}, {acc_rec, acc_clk})
        end
      end)

    {:ok, record}
  end

  defp resolve_read(_), do: {:error, :unavailable}
end
