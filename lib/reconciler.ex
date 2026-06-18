defmodule DS.Reconciler do
  use GenServer

  @reconcile_interval :timer.seconds(30)

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    schedule_reconcile()
    {:ok, %{}}
  end

  def handle_info(:reconcile, state) do
    reconcile()
    schedule_reconcile()
    {:noreply, state}
  end

  defp schedule_reconcile() do
    Process.send_after(self(), :reconcile, @reconcile_interval)
  end

  @scan_batch 100

  defp reconcile() do
    ms = [{:"$1", [], [:"$1"]}]
    do_scan_with_update(:ets.select(:primary, ms, @scan_batch))
  end

  defp do_scan_with_update(:"$end_of_table"), do: :ok

  defp do_scan_with_update({rows, continuation}) do
    Enum.each(rows, fn {{entity, key}, record, _clock} ->
      reconcile_record(entity, key, record)
    end)

    do_scan_with_update(:ets.select(continuation))
  end

  def reconcile_record(entity, key, record) do
    Enum.each(record, fn {field, {_type, true_value, _clock}} ->
      case DS.Storage.Index.indexed_value(entity, field, key) do
        {:ok, ^true_value} ->
          :ok

        {:ok, stale_value} ->
          DS.Storage.Index.fix_entry(entity, field, key, stale_value, true_value)

        {:error, :no_index} ->
          :ok

        {:error, :not_found} ->
          DS.Storage.Index.fix_entry(entity, field, key, nil, true_value)
      end
    end)
  end
end
