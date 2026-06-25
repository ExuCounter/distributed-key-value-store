defmodule DS.Rebalancer do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    :net_kernel.monitor_nodes(true)
    state = %{role: :follower, pending_timers: %{}}
    {:ok, state, {:continue, :elect}}
  end

  def handle_continue(:elect, state) do
    new_state = elect(state)

    if new_state.role == :follower do
      case :global.whereis_name(:ds_rebalancer) do
        :undefined -> :ok
        leader_pid -> send(leader_pid, :request_rebalance)
      end
    end

    {:noreply, new_state}
  end

  def handle_info(:request_rebalance, %{role: :leader} = state) do
    rebalance(DS.Router.all_nodes())
    {:noreply, state}
  end

  def handle_info(:request_rebalance, state) do
    {:noreply, state}
  end

  # A node joined the cluster.
  def handle_info({:nodeup, _joined_node}, %{role: :leader} = state) do
    rebalance(DS.Router.all_nodes())
    {:noreply, cancel_pending_timers(state)}
  end

  def handle_info({:nodeup, _joined_node}, state) do
    {:noreply, state}
  end

  # A node left the cluster. Delay before reacting, so a brief flap
  # does not trigger an expensive rebalance.
  def handle_info({:nodedown, departed_node}, %{role: :leader} = state) do
    timer_reference =
      Process.send_after(self(), {:do_rebalance, departed_node}, DS.Config.rebalance_delay())

    updated_timers = Map.put(state.pending_timers, departed_node, timer_reference)
    {:noreply, %{state | pending_timers: updated_timers}}
  end

  def handle_info({:nodedown, _departed_node}, state) do
    {:noreply, state}
  end

  # The delayed rebalance fires after the grace period.
  def handle_info({:do_rebalance, departed_node}, %{role: :leader} = state) do
    rebalance(DS.Router.all_nodes())
    updated_timers = Map.delete(state.pending_timers, departed_node)
    {:noreply, %{state | pending_timers: updated_timers}}
  end

  def handle_info({:do_rebalance, _departed_node}, state) do
    {:noreply, state}
  end

  # The leader process died; our link fired. Try to take over.
  def handle_info({:EXIT, _dead_pid, _reason}, state) do
    {:noreply, elect(state)}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  # --- Leader election ---

  defp elect(state) do
    case :global.register_name(:ds_rebalancer, self()) do
      :yes ->
        rebalance(DS.Router.all_nodes())
        %{state | role: :leader}

      :no ->
        leader_pid = :global.whereis_name(:ds_rebalancer)
        Process.link(leader_pid)
        %{state | role: :follower}
    end
  end

  # --- Slot assignment and broadcast ---

  defp rebalance(nodes) do
    assignments = assign_slots(nodes)

    DS.Routing.bulk_update(assignments)

    Enum.each(Node.list(), fn remote_node ->
      GenServer.cast({DS.Routing, remote_node}, {:bulk_update, assignments})
    end)
  end

  defp assign_slots(nodes) do
    sorted_nodes = Enum.sort(nodes)
    node_count = length(sorted_nodes)

    for slot <- 0..(DS.Config.slots() - 1) do
      owner = Enum.at(sorted_nodes, rem(slot, node_count))
      {slot, owner}
    end
  end

  defp cancel_pending_timers(state) do
    Enum.each(state.pending_timers, fn {_node, timer_reference} ->
      Process.cancel_timer(timer_reference)
    end)

    %{state | pending_timers: %{}}
  end
end
