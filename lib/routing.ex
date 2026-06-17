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

  # Server callbacks
  def init(_) do
    heir = Process.whereis(DS.Supervisor)

    :ets.new(:routing, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true},
      {:heir, heir, []}
    ])

    {:ok, :ok}
  end
end
