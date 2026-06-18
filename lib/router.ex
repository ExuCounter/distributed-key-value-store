defmodule DS.Router do
  @slots 1024
  @bucket_size 10
  @replication_factor 3

  def which_node(key) do
    slot = slot(key)
    DS.Routing.get_node(slot)
  end

  def replica_nodes(key), do: DS.Routing.replica_nodes(slot(key), @replication_factor)

  def all_nodes_for(key) do
    slot = slot(key)

    case DS.Routing.get_node(slot) do
      {:ok, owner} ->
        replicas = DS.Routing.replica_nodes(slot, @replication_factor - 1)
        {:ok, Enum.uniq([owner | replicas])}

      {:error, error} ->
        {:error, error}
    end
  end

  def which_nodes_for_range(entity, field, min, max) do
    first_bucket = resolve_first_bucket(entity, field, min)
    last_bucket = resolve_last_bucket(entity, field, max)

    first_bucket
    |> Stream.iterate(&(&1 + @bucket_size))
    |> Stream.take_while(&(&1 <= last_bucket))
    |> Enum.map(fn bucket_start ->
      slot = :erlang.phash2({entity, field, bucket_start}, @slots)
      DS.Routing.get_node(slot)
    end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, node} -> node end)
    |> Enum.uniq()
  end

  defp slot(key), do: :erlang.phash2(key, @slots)

  defp resolve_first_bucket(_entity, _field, min) when is_number(min) do
    div(min, @bucket_size) * @bucket_size
  end

  defp resolve_first_bucket(entity, field, :negative_infinity) do
    index_name = :"index_#{entity}_#{field}"

    case :ets.first(index_name) do
      :"$end_of_table" -> 0
      {value, _} -> div(value, @bucket_size) * @bucket_size
    end
  end

  defp resolve_last_bucket(_entity, _field, max) when is_number(max) do
    div(max, @bucket_size) * @bucket_size
  end

  defp resolve_last_bucket(entity, field, :infinity) do
    index_name = :"index_#{entity}_#{field}"

    case :ets.last(index_name) do
      :"$end_of_table" -> 0
      {value, _} -> div(value, @bucket_size) * @bucket_size
    end
  end
end
