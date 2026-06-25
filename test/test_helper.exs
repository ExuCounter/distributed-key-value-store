Application.stop(:ds)

unless Node.alive?() do
  :net_kernel.start(:"controller@127.0.0.1", %{name_domain: :longnames})
end

{:ok, _} = Application.ensure_all_started(:ds)

ExUnit.start()
