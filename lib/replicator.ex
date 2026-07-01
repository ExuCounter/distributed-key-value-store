defmodule DS.Replicator do
  def replicate(primary_key, fields) when is_map(fields) do
    fan_out(primary_key, fn node ->
      DS.Storage.Primary.remote_write(node, primary_key, fields)
    end)
  end

  def replicate_tombstone(primary_key, tombstone_clock) do
    fan_out(primary_key, fn node ->
      DS.Storage.Primary.remote_tombstone(node, primary_key, tombstone_clock)
    end)
  end

  defp fan_out(primary_key, operation) do
    nodes = DS.Router.replica_nodes(primary_key)
    quorum = DS.Config.write_quorum()

    result =
      DS.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        nodes,
        operation,
        timeout: DS.Config.replication_timeout(),
        on_timeout: :kill_task
      )
      |> Enum.reduce_while(0, fn
        {:ok, :ok}, count when count + 1 >= quorum -> {:halt, :ok}
        {:ok, :ok}, count -> {:cont, count + 1}
        _, count -> {:cont, count}
      end)

    case result do
      :ok -> :ok
      _ -> {:error, :unavailable}
    end
  end
end
