defmodule DS.Config do
  def slots, do: get(:slots, 1024)
  def replication_factor, do: get(:replication_factor, 3)
  def write_quorum, do: get(:write_quorum, 1)
  def read_quorum, do: get(:read_quorum, 2)
  def replication_timeout, do: get(:replication_timeout, 5_000)
  def reconcile_interval, do: get(:reconcile_interval, :timer.seconds(30))
  def rebalance_delay, do: get(:rebalance_delay, :timer.seconds(5))
  def resync_interval, do: get(:resync_interval, :timer.seconds(30))
  def scan_batch, do: get(:scan_batch, 100)

  defp get(key, default), do: Application.get_env(:ds, key, default)
end
