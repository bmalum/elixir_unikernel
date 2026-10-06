defmodule Uniapp.Probe do
  @moduledoc """
  Boot-time self test. Prints machine-readable `PROBE <name> ok|<error>` lines
  on the console so the smoke test can assert the MVP criteria:

    * udp     - :gen_udp open/send/recv to self
    * tcp     - :gen_tcp connect to our own echo server
    * dns     - inet_res resolution (needs uniapp.dns=)
    * tls     - :ssl.connect TLS 1.3 with the bundled CA store (needs uniapp.tls_host=)
    * tls_srv - :ssl.listen/accept with an ephemeral self-signed cert

  Each probe is independent; a failure never crashes the app.
  """
  use Task, restart: :temporary

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    # Give the echo server a moment to listen.
    Process.sleep(200)
    report("udp", &udp/0)
    report("tcp", &tcp/0)
    report("tls_srv", &tls_server/0)

    if host = Uniapp.Cmdline.get("uniapp.tls_host") do
      report("dns", fn -> dns(host) end)
      report("tls", fn -> tls(host) end)
    end

    IO.puts("PROBE done")
  end

  defp report(name, fun) do
    # Run each probe in its own unlinked process so a crash inside (or in a
    # Task it awaits) only fails that probe.
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

  defp udp do
    {:ok, s} = :gen_udp.open(0, [:binary, active: false])
    {:ok, port} = :inet.port(s)
    :ok = :gen_udp.send(s, {127, 0, 0, 1}, port, "ping")
    {:ok, {_, _, "ping"}} = :gen_udp.recv(s, 0, 2000)
    :gen_udp.close(s)
  end

  defp tcp do
    {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, Uniapp.Application.echo_port(), [:binary, packet: :line, active: false], 2000)
    :ok = :gen_tcp.send(s, "hello\n")
    {:ok, "hello\n"} = :gen_tcp.recv(s, 0, 2000)
    :gen_tcp.close(s)
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

  defp tls_server do
    {:ok, l} = :ssl.listen(0, Uniapp.SelfSigned.server_opts() ++ [versions: [:"tlsv1.3"], active: false, mode: :binary])
    {:ok, {_, port}} = :ssl.sockname(l)

    client =
      Task.async(fn ->
        {:ok, c} =
          :ssl.connect({127, 0, 0, 1}, port, [verify: :verify_none, versions: [:"tlsv1.3"], active: false, mode: :binary], 5000)
        :ok = :ssl.send(c, "tls-hello")
        {:ok, "tls-hello"} = :ssl.recv(c, 0, 5000)
        :ssl.close(c)
        :ok
      end)

    {:ok, t} = :ssl.transport_accept(l, 5000)
    {:ok, s} = :ssl.handshake(t, 5000)
    {:ok, data} = :ssl.recv(s, 0, 5000)
    :ok = :ssl.send(s, data)
    :ok = Task.await(client, 6000)
    :ssl.close(s)
    :ssl.close(l)
  end
end
