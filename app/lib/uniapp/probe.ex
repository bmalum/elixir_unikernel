defmodule Uniapp.Probe do
  @moduledoc """
  Boot-time outbound self test. Prints machine-readable `PROBE <name> ok|<error>`
  lines on the console for the smoke test:

    * dns  - `inet_res` resolution of `uniapp.tls_host` (pure-Erlang resolver)
    * tls  - `:ssl.connect` TLS 1.3 with `verify_peer` against the bundled CA store

  Both need `uniapp.tls_host=HOST` on the kernel command line. Listen-side
  checks (tcp/udp/tls servers) are driven from the host, see `Uniapp.Echo`.
  """
  use Task, restart: :temporary

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    if host = Uniapp.Cmdline.get("uniapp.tls_host") do
      report("dns", fn -> dns(host) end)
      report("tls", fn -> tls(host) end)
    end

    IO.puts("PROBE done")
    # Throughput self-test through the echo server, printed as BENCH for the smoke test.
    wait_ready(50)
    Uniapp.Health.bench()

    if peer = Uniapp.Cmdline.get("uniapp.bench_peer") do
      # Give the peer time to boot, then measure NIC to NIC (32 MB round trip).
      Process.sleep(String.to_integer(Uniapp.Cmdline.get("uniapp.bench_delay_ms", "30000")))
      Uniapp.Health.bench(peer, String.to_integer(Uniapp.Cmdline.get("uniapp.bench_mb", "32")) * 1024 * 1024)
    end
  end

  defp wait_ready(0), do: :ok
  defp wait_ready(n), do: if(Uniapp.Health.ready?(), do: :ok, else: (Process.sleep(100); wait_ready(n - 1)))

  defp report(name, fun) do
    # Run each probe in its own unlinked process so a crash only fails that probe.
    result =
      try do
        {pid, ref} = spawn_monitor(fn -> exit({:probe_result, fun.()}) end)

        receive do
          {:DOWN, ^ref, :process, ^pid, {:probe_result, r}} -> r
          {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
        after
          30_000 -> {:error, :timeout}
        end
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      :ok -> IO.puts("PROBE #{name} ok")
      {:ok, _} -> IO.puts("PROBE #{name} ok")
      other -> IO.puts("PROBE #{name} #{inspect(other, limit: 20)}")
    end
  end

  defp dns(host) do
    case :inet_res.getbyname(String.to_charlist(host), :a, 5000) do
      {:ok, {:hostent, _, _, :inet, 4, [_ | _]}} -> :ok
      other -> {:error, other}
    end
  end

  defp tls(host) do
    opts = [
      verify: :verify_peer,
      cacertfile: String.to_charlist(System.get_env("UNIAPP_CACERTS") || "/etc/ssl/cacert.pem"),
      versions: [:"tlsv1.3"],
      server_name_indication: String.to_charlist(host),
      depth: 3
    ]

    {:ok, s} = :ssl.connect(String.to_charlist(host), 443, opts, 10_000)
    {:ok, info} = :ssl.connection_information(s, [:protocol])
    :ssl.close(s)
    if info[:protocol] == :"tlsv1.3", do: :ok, else: {:error, info}
  end
end
