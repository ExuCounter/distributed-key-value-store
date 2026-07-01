Application.put_env(:kernel, :prevent_overlapping_partitions, false)

unless Node.alive?() do
  :net_kernel.start(:"controller@127.0.0.1", %{name_domain: :longnames})
end

ExUnit.start()
