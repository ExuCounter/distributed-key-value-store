defmodule DS.Router do
  @slots 1024
  @bucket_size 10

  def which_node(key) do
    slot = slot(key)
    DS.Routing.get_node(slot)
  end

  def which_nodes_for_range(field, min, max) do
    first_bucket = resolve_first_bucket(field, min)
    last_bucket = resolve_last_bucket(field, max)

    first_bucket
    |> Stream.iterate(&(&1 + @bucket_size))
    |> Stream.take_while(&(&1 <= last_bucket))
    |> Enum.map(fn bucket_start ->
      slot = :erlang.phash2({field, bucket_start}, @slots)
      DS.Routing.get_node(slot)
    end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, node} -> node end)
    |> Enum.uniq()
  end

  def get_replica_nodes(slot, n) do
    all = DS.Routing.all_slots() |> Enum.sort_by(fn {s, _} -> s end)

    {after_slot, before_slot} = Enum.split_while(all, fn {s, _} -> s <= slot end)
    ring = before_slot ++ after_slot

    ring
    |> Enum.map(fn {_, node} -> node end)
    |> Enum.uniq()
    |> Enum.take(n)
  end

  # Private
  defp slot(key), do: :erlang.phash2(key, @slots)

  defp resolve_first_bucket(_field, min) when is_number(min) do
    div(min, @bucket_size) * @bucket_size
  end

  defp resolve_first_bucket(field, :negative_infinity) do
    index_name = :"index_#{field}"

    case :ets.first(index_name) do
      :"$end_of_table" -> 0
      {value, _} -> div(value, @bucket_size) * @bucket_size
    end
  end

  defp resolve_last_bucket(_field, max) when is_number(max) do
    div(max, @bucket_size) * @bucket_size
  end

  defp resolve_last_bucket(field, :infinity) do
    index_name = :"index_#{field}"

    case :ets.last(index_name) do
      :"$end_of_table" -> 0
      {value, _} -> div(value, @bucket_size) * @bucket_size
    end
  end
end
