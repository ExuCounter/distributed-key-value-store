defmodule DS.Storage.Primary do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :ets.new(:primary, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true}
    ])

    {:ok, :ok}
  end

  def get_raw(primary_key) do
    case :ets.lookup(:primary, primary_key) do
      [{^primary_key, value, clock}] -> {:ok, {value, clock}}
      [] -> {:error, :not_found}
    end
  end

  def get(primary_key) do
    case get_raw(primary_key) do
      {:ok, {:tombstone, _clock}} -> {:error, :not_found}
      other -> other
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
    {:ok, clock}
  end

  def put(primary_key, :tombstone, clock) when is_map(clock) do
    cleanup_indexes(primary_key)
    :ets.insert(:primary, {primary_key, :tombstone, clock})
    {:ok, clock}
  end

  def put(primary_key, record, clock) when is_map(clock) do
    :ets.insert(:primary, {primary_key, record, clock})
    update_indexes(primary_key, record)
    {:ok, clock}
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

  def tombstone(primary_key, node) when is_atom(node) do
    old = get_raw(primary_key)

    clock =
      case old do
        {:ok, {_value, existing_clock}} -> DS.VectorClock.increment(existing_clock, node)
        {:error, :not_found} -> DS.VectorClock.increment(%{}, node)
      end

    put(primary_key, :tombstone, clock)
  end

  defp update_indexes({entity, key}, record) do
    Enum.each(record, fn {field, value} ->
      DS.Storage.Index.update_index(entity, field, key, value)
    end)
  end

  defp delete_indexes({entity, key}, record) do
    Enum.each(record, fn {field, value} ->
      DS.Storage.Index.delete_index_entry(entity, field, key, value)
    end)
  end

  defp cleanup_indexes(primary_key) do
    case get_raw(primary_key) do
      {:ok, {record, _}} when record != :tombstone ->
        delete_indexes(primary_key, record)

      _ ->
        :ok
    end
  end

  def bulk_put(rows) do
    :ets.insert(:primary, rows)
    :ok
  end

  def remote_write(node, primary_key, record, clock) do
    GenServer.call({__MODULE__, node}, {:write, primary_key, record, clock})
  end

  def remote_read(node, primary_key) do
    GenServer.call({__MODULE__, node}, {:read, primary_key})
  end

  def handle_call({:write, primary_key, record, clock}, _from, state) do
    put(primary_key, record, clock)
    {:reply, :ok, state}
  end

  def handle_call({:read, primary_key}, _from, state) do
    result = get(primary_key)
    {:reply, result, state}
  end
end
