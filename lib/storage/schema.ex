defmodule DS.Storage.Schema do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    heir = Process.whereis(DS.Supervisor)

    :ets.new(:schemas, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true},
      {:heir, heir, []}
    ])

    {:ok, :ok}
  end

  def register(entity, schema) do
    GenServer.call(__MODULE__, {:register, entity, schema})
  end

  def get(entity) do
    case :ets.lookup(:schemas, entity) do
      [{^entity, schema}] -> {:ok, schema}
      [] -> {:error, :not_found}
    end
  end

  def get_field(entity, field) do
    case get(entity) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, schema} ->
        case Map.get(schema, field) do
          nil -> {:error, :field_not_found}
          value -> {:ok, value}
        end
    end
  end

  def valid_field?(entity, field) do
    case get_field(entity, field) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  def handle_call({:register, entity, schema}, _from, state) do
    :ets.insert(:schemas, {entity, schema})

    Node.list()
    |> Enum.each(fn node ->
      GenServer.cast({DS.Storage.Schema, node}, {:register, entity, schema})
    end)

    {:reply, :ok, state}
  end

  def handle_cast({:register, entity, schema}, state) do
    :ets.insert(:schemas, {entity, schema})
    {:noreply, state}
  end
end
