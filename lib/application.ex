defmodule DS.Application do
  use Application

  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      {Cluster.Supervisor, [topologies, [name: DS.ClusterSupervisor]]},
      {Task.Supervisor, name: DS.TaskSupervisor},
      DS.Storage.Schema,
      DS.Storage.Primary,
      DS.Storage.Index,
      DS.Routing,
      DS.Reconciler,
      DS.Rebalancer
    ]

    Supervisor.start_link(children, strategy: :rest_for_one)
  end
end
