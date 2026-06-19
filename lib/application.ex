defmodule DS.Application do
  use Application

  def start(_type, _args) do
    topologies = [
      local: [
        strategy: Cluster.Strategy.Epmd,
        config: [
          hosts: [
            :"node1@127.0.0.1",
            :"node2@127.0.0.1",
            :"node3@127.0.0.1"
          ]
        ]
      ]
    ]

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
