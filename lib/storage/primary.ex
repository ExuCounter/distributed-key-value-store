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

  def get(key) do
    case :ets.lookup(:primary, key) do
      [{^key, record, clock}] -> {:ok, {record, clock}}
      [] -> {:error, :not_found}
    end
  end

  def put(key, record, node) when is_atom(node) do
    clock =
      case get(key) do
        {:ok, {_record, existing_clock}} -> DS.VectorClock.increment(existing_clock, node)
        {:error, :not_found} -> DS.VectorClock.increment(%{}, node)
      end

    :ets.insert(:primary, {key, record, clock})
    :ok
  end

  def put(key, record, clock) when is_map(clock) do
    :ets.insert(:primary, {key, record, clock})
    :ok
  end

  def delete(key) do
    case get(key) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, _} ->
        :ets.delete(:primary, key)
        :ok
    end
  end

  def bulk_put(records) do
    :ets.insert(:primary, records)
    :ok
  end
end
