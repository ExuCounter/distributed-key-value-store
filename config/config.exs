import Config

config :ds,
  slots: 1024,
  replication_factor: 3,
  write_quorum: 1,
  read_quorum: 2,
  replication_timeout: 5_000,
  reconcile_interval: :timer.seconds(30),
  rebalance_delay: :timer.seconds(5),
  resync_interval: :timer.seconds(2),
  scan_batch: 100

import_config "#{config_env()}.exs"
