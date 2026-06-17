defmodule DS.Replicator do
  @quorum 2
  @timeout 5_000

  def replicate(key, record, clock) do
    nodes = DS.Router.replica_nodes(key)

    result =
      nodes
      |> Task.async_stream(
        fn node ->
          DS.Storage.Primary.remote_write(node, key, record, clock)
        end,
        timeout: @timeout,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while(0, fn
        {:ok, :ok}, count when count + 1 >= @quorum ->
          {:halt, :ok}

        {:ok, :ok}, count ->
          {:cont, count + 1}

        _, count ->
          {:cont, count}
      end)

    case result do
      :ok -> :ok
      _ -> {:error, :unavailable}
    end
  end
end
