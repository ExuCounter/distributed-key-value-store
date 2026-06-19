defmodule DS.Reconciler do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    schedule_reconcile()
    {:ok, %{}}
  end

  def handle_info(:reconcile, state) do
    reconcile()
    remove_orphaned_index_entries()
    schedule_reconcile()
    {:noreply, state}
  end

  def remove_orphaned_index_entries do
    Enum.each(DS.Storage.Index.index_pairs(), fn {entity, field} ->
      cleanup_forward_index(entity, field)
      cleanup_reverse_index(entity, field)
    end)
  end

  defp cleanup_forward_index(entity, field) do
    table = DS.Storage.Index.forward_index_name(entity, field)
    ms = [{:"$1", [], [:"$1"]}]
    do_cleanup_forward(:ets.select(table, ms, DS.Config.scan_batch()), entity, field)
  end

  defp do_cleanup_forward(:"$end_of_table", _entity, _field), do: :ok

  defp do_cleanup_forward({rows, continuation}, entity, field) do
    Enum.each(rows, fn {{value, key}, _} ->
      case DS.Storage.Primary.get({entity, key}) do
        {:ok, _} -> :ok
        {:error, :not_found} -> DS.Storage.Index.delete_forward_row(entity, field, key, value)
      end
    end)

    do_cleanup_forward(:ets.select(continuation), entity, field)
  end

  defp cleanup_reverse_index(entity, field) do
    table = DS.Storage.Index.reverse_index_name(entity, field)
    ms = [{:"$1", [], [:"$1"]}]
    do_cleanup_reverse(:ets.select(table, ms, DS.Config.scan_batch()), entity, field)
  end

  defp do_cleanup_reverse(:"$end_of_table", _entity, _field), do: :ok

  defp do_cleanup_reverse({rows, continuation}, entity, field) do
    Enum.each(rows, fn {key, value} ->
      case DS.Storage.Primary.get({entity, key}) do
        {:ok, _} -> :ok
        {:error, :not_found} -> DS.Storage.Index.delete_reverse_row(entity, field, key, value)
      end
    end)

    do_cleanup_reverse(:ets.select(continuation), entity, field)
  end

  defp schedule_reconcile() do
    Process.send_after(self(), :reconcile, DS.Config.reconcile_interval())
  end

  defp reconcile() do
    ms = [{:"$1", [], [:"$1"]}]
    do_scan_with_update(:ets.select(:primary, ms, DS.Config.scan_batch()))
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
