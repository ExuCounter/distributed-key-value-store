defmodule DS.Storage.Schema do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    :ets.new(:schemas, [:named_table, :set, :public, {:read_concurrency, true}])
    schedule_resync()
    {:ok, %{}, {:continue, :sync}}
  end

  def handle_continue(:sync, state) do
    sync_from_peers(Node.list())
    {:noreply, state}
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

  def handle_info(:resync, state) do
    sync_from_peers(Node.list())
    schedule_resync()
    {:noreply, state}
  end

  # --- Schema synchronization ---

  defp sync_from_peers([]), do: :ok

  defp sync_from_peers(peers) do
    Enum.reduce_while(peers, :no_peer, fn peer, _accumulator ->
      case fetch_schemas(peer) do
        {:ok, schemas} ->
          Enum.each(schemas, fn {entity, schema} ->
            :ets.insert(:schemas, {entity, schema})
          end)

          {:halt, :ok}

        :error ->
          {:cont, :no_peer}
      end
    end)
  end

  defp fetch_schemas(peer) do
    {:ok, :erpc.call(peer, __MODULE__, :all_schemas, [], 5_000)}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp schedule_resync do
    Process.send_after(self(), :resync, DS.Config.resync_interval())
  end

  def all_schemas do
    :ets.tab2list(:schemas)
  end
end
