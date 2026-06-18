defmodule DS.Storage.Index do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    heir = Process.whereis(DS.Supervisor)

    :ets.new(:indexes, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true},
      {:heir, heir, []}
    ])

    {:ok, :ok}
  end

  def create_index(entity, field) do
    GenServer.call(__MODULE__, {:create_index, entity, field})
  end

  def update_index(entity, field, key, new_value) do
    case :ets.lookup(:indexes, {entity, field}) do
      [] ->
        :ok

      [_] ->
        case reverse_index_get(entity, field, key) do
          {:ok, old_value} ->
            forward_index_delete(entity, field, key, old_value)
            reverse_index_delete(entity, field, key, old_value)

          :error ->
            :ok
        end

        forward_index_put(entity, field, key, new_value)
        reverse_index_put(entity, field, key, new_value)
        :ok
    end
  end

  def where(entity, field, min, max) do
    case :ets.lookup(:indexes, {entity, field}) do
      [] ->
        full_scan(entity, field, min, max)

      [_] ->
        guards = build_guards(min, max)
        :ets.select(forward_index_name(entity, field), [{{:"$1", :"$2"}, guards, [:"$2"]}])
    end
  end

  def delete_index_entry(entity, field, key, value) do
    case :ets.lookup(:indexes, {entity, field}) do
      [] ->
        :ok

      [_] ->
        forward_index_delete(entity, field, key, value)
        reverse_index_delete(entity, field, key, value)
        :ok
    end
  end

  def indexed_value(entity, field, key) do
    case :ets.lookup(:indexes, {entity, field}) do
      [] ->
        {:error, :no_index}

      [_] ->
        case reverse_index_get(entity, field, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
    end
  end

  def fix_entry(entity, field, key, stale_value, true_value) do
    case :ets.lookup(:indexes, {entity, field}) do
      [] ->
        :ok

      [_] ->
        if stale_value do
          forward_index_delete(entity, field, key, stale_value)
          reverse_index_delete(entity, field, key, stale_value)
        end

        forward_index_put(entity, field, key, true_value)
        reverse_index_put(entity, field, key, true_value)
        :ok
    end
  end

  def handle_call({:create_index, entity, field}, _from, state) do
    case DS.Storage.Schema.get_field(entity, field) do
      {:error, _} ->
        {:reply, {:error, :field_schema_not_found}, state}

      {:ok, _} ->
        case :ets.lookup(:indexes, {entity, field}) do
          [_] ->
            {:reply, {:error, :index_already_exists}, state}

          [] ->
            heir = Process.whereis(DS.Supervisor)

            :ets.new(forward_index_name(entity, field), [
              :named_table,
              :ordered_set,
              :public,
              {:read_concurrency, true},
              {:heir, heir, []}
            ])

            :ets.new(reverse_index_name(entity, field), [
              :named_table,
              :set,
              :public,
              {:read_concurrency, true},
              {:heir, heir, []}
            ])

            :ets.insert(:indexes, {{entity, field}, :ok})
            {:reply, :ok, state}
        end
    end
  end

  def index_pairs do
    :indexes
    |> :ets.tab2list()
    |> Enum.map(fn {{entity, field}, _} -> {entity, field} end)
  end

  def forward_index_name(entity, field), do: :"index_#{entity}_#{field}"
  def reverse_index_name(entity, field), do: :"rindex_#{entity}_#{field}"

  def delete_forward_row(entity, field, key, value),
    do: forward_index_delete(entity, field, key, value)

  def delete_reverse_row(entity, field, key, value),
    do: reverse_index_delete(entity, field, key, value)

  defp forward_index_put(entity, field, key, value),
    do: :ets.insert(forward_index_name(entity, field), {value, key})

  defp forward_index_delete(entity, field, key, value),
    do: :ets.delete_object(forward_index_name(entity, field), {value, key})

  defp reverse_index_put(entity, field, key, value),
    do: :ets.insert(reverse_index_name(entity, field), {key, value})

  defp reverse_index_delete(entity, field, key, value),
    do: :ets.delete_object(reverse_index_name(entity, field), {key, value})

  defp reverse_index_get(entity, field, key) do
    case :ets.lookup(reverse_index_name(entity, field), key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  defp build_guards(min, max) do
    []
    |> add_min_guard(min)
    |> add_max_guard(max)
  end

  defp add_min_guard(guards, :negative_infinity), do: guards
  defp add_min_guard(guards, min), do: [{:>=, :"$1", min} | guards]

  defp add_max_guard(guards, :infinity), do: guards
  defp add_max_guard(guards, max), do: [{:"=<", :"$1", max} | guards]

  @scan_batch 100

  defp full_scan(entity, field, min, max) do
    match_spec = [{{{entity, :"$1"}, :"$2", :"$3"}, [], [:"$1"]}]
    do_scan(:ets.select(:primary, match_spec, @scan_batch), entity, field, min, max, [])
  end

  defp do_scan(:"$end_of_table", _entity, _field, _min, _max, acc), do: acc

  defp do_scan({keys, continuation}, entity, field, min, max, acc) do
    matches =
      Enum.filter(keys, fn key ->
        case DS.Storage.Primary.get({entity, key}) do
          {:ok, {record, _clock}} ->
            value = Map.get(record, field)
            value && above_min?(value, min) && below_max?(value, max)

          _ ->
            false
        end
      end)

    do_scan(:ets.select(continuation), entity, field, min, max, acc ++ matches)
  end

  defp above_min?(_value, :negative_infinity), do: true
  defp above_min?(value, min), do: value >= min

  defp below_max?(_value, :infinity), do: true
  defp below_max?(value, max), do: value <= max
end
