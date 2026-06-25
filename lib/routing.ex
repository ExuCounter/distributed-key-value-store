defmodule DS.Routing do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def get_node(slot) do
    case :ets.lookup(:routing, slot) do
      [{^slot, node}] -> {:ok, node}
      [] -> {:error, :service_unavailable}
    end
  end

  def put_slot(slot, node) do
    :ets.insert(:routing, {slot, node})
    :ok
  end

  def bulk_update(slot_node_list) do
    :ets.insert(:routing, slot_node_list)
    :ok
  end

  def all_slots() do
    :ets.tab2list(:routing)
  end

  def replica_nodes(slot, n) do
    case get_node(slot) do
      {:error, _} ->
        []

      {:ok, owner} ->
        sorted = all_slots() |> Enum.sort_by(fn {s, _} -> s end)
        {before_or_at, after_slot} = Enum.split_while(sorted, fn {s, _} -> s <= slot end)
        ring = after_slot ++ before_or_at

        ring
        |> Enum.map(fn {_, node} -> node end)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == owner))
        |> Enum.take(n)
    end
  end

  def init(_) do
    :ets.new(:routing, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true}
    ])

    {:ok, :ok}
  end

  def handle_cast({:bulk_update, assignments}, state) do
    bulk_update(assignments)
    {:noreply, state}
  end
end
