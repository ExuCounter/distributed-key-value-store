defmodule DS do
  def register_schema(entity, schema), do: DS.Storage.Schema.register(entity, schema)
  def create_index(entity, field), do: DS.Storage.Index.create_index(entity, field)

  def get(entity, key) do
    DS.Reader.read({entity, key})
  end

  def put(entity, key, record) do
    primary_key = {entity, key}

    case DS.Router.which_node(primary_key) do
      {:error, :service_unavailable} ->
        {:error, :service_unavailable}

      {:ok, owner} when owner == node() ->
        {:ok, clock} = DS.Storage.Primary.put(primary_key, record, owner)
        DS.Replicator.replicate(primary_key, record, clock)

      {:ok, owner} ->
        forward(owner, :put, [entity, key, record])
    end
  end

  def tombstone(entity, key) do
    primary_key = {entity, key}

    case DS.Router.which_node(primary_key) do
      {:error, :service_unavailable} ->
        {:error, :service_unavailable}

      {:ok, owner} when owner == node() ->
        {:ok, clock} = DS.Storage.Primary.tombstone(primary_key, owner)
        DS.Replicator.replicate(primary_key, :tombstone, clock)

      {:ok, owner} ->
        forward(owner, :tombstone, [entity, key])
    end
  end

  defp forward(node, fun, args) do
    :erpc.call(node, __MODULE__, fun, args, 5_000)
  rescue
    _ -> {:error, :node_unreachable}
  catch
    :exit, _ -> {:error, :node_unreachable}
  end
end
