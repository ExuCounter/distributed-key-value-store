defmodule DS.Storage.Primary do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    heir = Process.whereis(DS.Supervisor)

    :ets.new(:primary, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true},
      {:heir, heir, []}
    ])

    {:ok, :ok}
  end

  def get(primary_key) do
    case :ets.lookup(:primary, primary_key) do
      [{^primary_key, record, clock}] -> {:ok, {record, clock}}
      [] -> {:error, :not_found}
    end
  end

  def put(primary_key, record, node) when is_atom(node) do
    clock =
      case get(primary_key) do
        {:ok, {_record, existing_clock}} -> DS.VectorClock.increment(existing_clock, node)
        {:error, :not_found} -> DS.VectorClock.increment(%{}, node)
      end

    :ets.insert(:primary, {primary_key, record, clock})
    update_indexes(primary_key, record)
    :ok
  end

  def put(primary_key, record, clock) when is_map(clock) do
    :ets.insert(:primary, {primary_key, record, clock})
    update_indexes(primary_key, record)
    :ok
  end

  def delete(primary_key) do
    case get(primary_key) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, {record, _clock}} ->
        delete_indexes(primary_key, record)
        :ets.delete(:primary, primary_key)
        :ok
    end
  end

  defp update_indexes({entity, key}, record) do
    Enum.each(record, fn {field, {_type, value, _clock}} ->
      DS.Storage.Index.update_index(entity, field, key, value)
    end)
  end

  defp delete_indexes({entity, key}, record) do
    Enum.each(record, fn {field, {_type, value, _clock}} ->
      DS.Storage.Index.delete_index_entry(entity, field, key, value)
    end)
  end

  def bulk_put(rows) do
    :ets.insert(:primary, rows)
    :ok
  end

  def handle_call({:write, primary_key, record, clock}, _from, state) do
    put(primary_key, record, clock)
    {:reply, :ok, state}
  end
end
