defmodule DS.Storage.Primary do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :ets.new(:primary, [:named_table, :set, :public, {:read_concurrency, true}])
    {:ok, :ok}
  end

  def get_raw(primary_key) do
    case :ets.lookup(:primary, primary_key) do
      [{^primary_key, :tombstone, tombstone_clock}] ->
        {:ok, {:tombstone, tombstone_clock}}

      [{^primary_key, fields, :live}] ->
        {:ok, {fields, record_clock(fields)}}

      [] ->
        {:error, :not_found}
    end
  end

  def get(primary_key) do
    case :ets.lookup(:primary, primary_key) do
      [{^primary_key, :tombstone, _}] ->
        {:error, :not_found}

      [{^primary_key, fields, :live}] ->
        {:ok, {to_record(fields), record_clock(fields)}}

      [] ->
        {:error, :not_found}
    end
  end

  def get_fields(primary_key) do
    case :ets.lookup(:primary, primary_key) do
      [{^primary_key, :tombstone, _}] -> {:error, :not_found}
      [{^primary_key, fields, :live}] -> {:ok, fields}
      [] -> {:error, :not_found}
    end
  end

  def put(primary_key, record, node) when is_atom(node) and is_map(record) do
    existing_fields =
      case get_fields(primary_key) do
        {:ok, fields} -> fields
        _ -> %{}
      end

    new_fields =
      Enum.reduce(record, existing_fields, fn {field, value}, accumulator ->
        existing_clock =
          case Map.get(accumulator, field) do
            {_value, clock} -> clock
            nil -> %{}
          end

        Map.put(accumulator, field, {value, DS.VectorClock.increment(existing_clock, node)})
      end)

    :ets.insert(:primary, {primary_key, new_fields, :live})
    update_indexes(primary_key, to_record(new_fields))
    {:ok, new_fields}
  end

  def merge(primary_key, incoming_fields) when is_map(incoming_fields) do
    {entity, _} = primary_key

    existing_fields =
      case get_fields(primary_key) do
        {:ok, fields} -> fields
        _ -> %{}
      end

    merged = DS.CRDT.merge_fields(existing_fields, incoming_fields, entity)

    :ets.insert(:primary, {primary_key, merged, :live})
    update_indexes(primary_key, to_record(merged))
    {:ok, merged}
  end

  def tombstone(primary_key, node) when is_atom(node) do
    existing_clock = max_clock(primary_key)
    tombstone_clock = DS.VectorClock.increment(existing_clock, node)
    write_tombstone(primary_key, tombstone_clock)
    {:ok, tombstone_clock}
  end

  def merge_tombstone(primary_key, incoming_clock) do
    existing_clock = max_clock(primary_key)
    merged = DS.VectorClock.merge(existing_clock, incoming_clock)
    write_tombstone(primary_key, merged)
    {:ok, merged}
  end

  def delete(primary_key) do
    case get_fields(primary_key) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, fields} ->
        delete_indexes(primary_key, to_record(fields))
        :ets.delete(:primary, primary_key)
        :ok
    end
  end

  def remote_write(node, primary_key, fields) when is_map(fields) do
    GenServer.call({__MODULE__, node}, {:merge, primary_key, fields})
  end

  def remote_tombstone(node, primary_key, tombstone_clock) do
    GenServer.call({__MODULE__, node}, {:merge_tombstone, primary_key, tombstone_clock})
  end

  def remote_read(node, primary_key) do
    GenServer.call({__MODULE__, node}, {:read, primary_key})
  end

  def remote_read_raw(node, primary_key) do
    GenServer.call({__MODULE__, node}, {:read_raw, primary_key})
  end

  def handle_call({:merge, primary_key, fields}, _from, state) do
    merge(primary_key, fields)
    {:reply, :ok, state}
  end

  def handle_call({:merge_tombstone, primary_key, tombstone_clock}, _from, state) do
    merge_tombstone(primary_key, tombstone_clock)
    {:reply, :ok, state}
  end

  def handle_call({:read, primary_key}, _from, state) do
    {:reply, get(primary_key), state}
  end

  def handle_call({:read_raw, primary_key}, _from, state) do
    {:reply, get_raw(primary_key), state}
  end

  defp write_tombstone(primary_key, tombstone_clock) do
    case get_fields(primary_key) do
      {:ok, fields} -> delete_indexes(primary_key, to_record(fields))
      _ -> :ok
    end

    :ets.insert(:primary, {primary_key, :tombstone, tombstone_clock})
  end

  defp max_clock(primary_key) do
    case :ets.lookup(:primary, primary_key) do
      [{^primary_key, :tombstone, tombstone_clock}] -> tombstone_clock
      [{^primary_key, fields, :live}] -> record_clock(fields)
      [] -> %{}
    end
  end

  defp record_clock(fields) do
    fields
    |> Map.values()
    |> Enum.reduce(%{}, fn {_value, clock}, accumulator ->
      DS.VectorClock.merge(accumulator, clock)
    end)
  end

  defp to_record(fields) do
    Map.new(fields, fn {field, {value, _clock}} -> {field, value} end)
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
end
