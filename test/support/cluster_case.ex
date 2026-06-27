defmodule DS.ClusterCase do
  use ExUnit.CaseTemplate

  @cookie_arg ~c"-setcookie"

  using do
    quote do
      use ExUnit.Case, async: false
      import DS.ClusterCase
    end
  end

  setup_all do
    ensure_distribution()
    Application.stop(:ds)
    {:ok, _} = Application.ensure_all_started(:ds)

    suffix = :erlang.unique_integer([:positive])
    peer_names = [:"p1_#{suffix}", :"p2_#{suffix}"]
    peers = Enum.map(peer_names, &start_peer/1)
    nodes = [node() | Enum.map(peers, &elem(&1, 1))]

    wait_for_routing(nodes)

    on_exit(fn ->
      Enum.each(peers, fn {pid, _node} ->
        try do
          :peer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      Application.stop(:ds)
    end)

    {:ok, peers: Enum.map(peers, &elem(&1, 1)), nodes: nodes}
  end

  defp ensure_distribution do
    unless Node.alive?() do
      :net_kernel.start(:"controller@127.0.0.1", %{name_domain: :longnames})
    end
  end

  setup %{nodes: nodes} do
    Enum.each(nodes, &reset_state/1)
    :ok
  end

  def start_peer(short_name) do
    {:ok, pid, node} =
      :peer.start(%{
        name: short_name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: [@cookie_arg, Atom.to_charlist(Node.get_cookie())]
      })

    Node.connect(node)

    :erpc.call(node, :code, :add_paths, [:code.get_path()])

    for {key, value} <- Application.get_all_env(:ds) do
      :erpc.call(node, Application, :put_env, [:ds, key, value])
    end

    :erpc.call(node, Application, :put_env, [:libcluster, :topologies, []])

    :global.sync()
    :erpc.call(node, :global, :sync, [])

    {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:ds])

    {pid, node}
  end

  def reset_state(node) when node == node() do
    do_reset()
  end

  def reset_state(node) do
    :erpc.call(node, __MODULE__, :do_reset, [])
  end

  def do_reset do
    for {{entity, field}, _} <- :ets.tab2list(:indexes) do
      drop_table(DS.Storage.Index.forward_index_name(entity, field))
      drop_table(DS.Storage.Index.reverse_index_name(entity, field))
    end

    :ets.delete_all_objects(:indexes)
    :ets.delete_all_objects(:schemas)
    :ets.delete_all_objects(:primary)
    :ok
  end

  defp drop_table(name) do
    case :ets.info(name) do
      :undefined -> :ok
      _ -> :ets.delete(name)
    end
  end

  def eventually(timeout_ms \\ 1_000, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        ExUnit.Assertions.flunk("eventually condition was never true")
      else
        Process.sleep(20)
        do_eventually(fun, deadline)
      end
    end
  end

  def wait_for_routing(nodes, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_routing(nodes, deadline)
  end

  defp do_wait_for_routing(nodes, deadline) do
    cond do
      Enum.all?(nodes, &routing_populated?/1) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, :routing_not_ready}

      true ->
        Process.sleep(20)
        do_wait_for_routing(nodes, deadline)
    end
  end

  defp routing_populated?(node) when node == node() do
    :ets.info(:routing, :size) > 0
  end

  defp routing_populated?(node) do
    case :erpc.call(node, :ets, :info, [:routing, :size]) do
      n when is_integer(n) and n > 0 -> true
      _ -> false
    end
  end
end
