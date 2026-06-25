import Config

config :libcluster,
  topologies: [
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
