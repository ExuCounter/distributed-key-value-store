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

  def update_index(entity, field, id, old_value, new_value) do
    case :ets.lookup(:indexes, {entity, field}) do
      [] ->
        :ok

      [{_, index_name}] ->
        if old_value, do: :ets.delete_object(index_name, {old_value, id})
        :ets.insert(index_name, {new_value, id})
    end
  end

  def where(entity, field, min, max) do
    case :ets.lookup(:indexes, {entity, field}) do
      [] ->
        full_scan(entity, field, min, max)

      [{_, index_name}] ->
        guards = build_guards(min, max)
        :ets.select(index_name, [{{:"$1", :"$2"}, guards, [:"$2"]}])
    end
  end

  def delete_index_entry(entity, field, id, value) do
    case :ets.lookup(:indexes, {entity, field}) do
      [] ->
        :ok

      [{_, index_name}] ->
        :ets.delete_object(index_name, {value, id})
    end
  end

  def handle_call({:create_index, entity, field}, _from, state) do
    case DS.Storage.Schema.get_field(entity, field) do
      {:error, _} ->
        {:reply, {:error, :field_schema_not_found}, state}

      {:ok, _} ->
        index_name = build_index_name(entity, field)

        case :ets.lookup(:indexes, {entity, field}) do
          [_] ->
            {:reply, {:error, :index_already_exists}, state}

          [] ->
            heir = Process.whereis(DS.Supervisor)

            :ets.new(index_name, [
              :named_table,
              :ordered_set,
              :public,
              {:read_concurrency, true},
              {:heir, heir, []}
            ])

            :ets.insert(:indexes, {{entity, field}, index_name})
            {:reply, :ok, state}
        end
    end
  end

  defp build_index_name(entity, field), do: :"index_#{entity}_#{field}"

  defp build_guards(min, max) do
    []
    |> add_min_guard(min)
    |> add_max_guard(max)
  end

  defp add_min_guard(guards, :negative_infinity), do: guards
  defp add_min_guard(guards, min), do: [{:>=, :"$1", min} | guards]

  defp add_max_guard(guards, :infinity), do: guards
  defp add_max_guard(guards, max), do: [{:"=<", :"$1", max} | guards]

  defp full_scan(entity, field, min, max) do
    match_spec = [{{{entity, :"$1"}, :"$2", :"$3"}, [], [:"$1"]}]
    do_scan(:ets.select(:primary, match_spec, 100), entity, field, min, max, [])
  end

  defp do_scan(:"$end_of_table", _entity, _field, _min, _max, acc), do: acc

  defp do_scan({ids, continuation}, entity, field, min, max, acc) do
    matches =
      Enum.filter(ids, fn id ->
        case DS.Storage.Primary.get({entity, id}) do
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
