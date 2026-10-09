defmodule Uniapp.Echo do
  @moduledoc """
  Echo servers that prove listen/accept inside the image over virtio-net:

    * tcp/4000  plain `:gen_tcp`
    * udp/4001  `:gen_udp` (datagrams echoed to the sender)
    * tcp/4443  `:ssl` (TLS 1.3, ephemeral self-signed cert)

  The smoke test connects to them from the host through QEMU port forwards.
  Failing listens are logged and retried instead of crashing the supervisor,
  so a missing socket feature on a new kernel cannot take the VM down.
  """
  use Task, restart: :permanent
  require Logger

  def start_link(opts), do: Task.start_link(__MODULE__, :run, [opts])

  @doc "Kinds (`:tcp`, `:udp`, `:tls`) that currently have a listen socket."
  def listening, do: :persistent_term.get({__MODULE__, :listening}, [])

  def run(opts) do
    kind = Keyword.fetch!(opts, :kind)
    port = Keyword.fetch!(opts, :port)

    case listen(kind, port) do
      {:ok, lsock} ->
        Logger.info("echo: listening #{kind}/#{port}")
        IO.puts("LISTEN #{kind} #{port}")
        :persistent_term.put({__MODULE__, :listening}, Enum.uniq([kind | listening()]))
        serve(kind, lsock)

      {:error, reason} ->
        Logger.error("echo: listen #{kind}/#{port} failed: #{inspect(reason)}; retrying in 5s")
        Process.sleep(5_000)
        run(opts)
    end
  end

  defp listen(:tcp, port), do: :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true])
  defp listen(:udp, port), do: :gen_udp.open(port, [:binary, active: false, reuseaddr: true])

  defp listen(:tls, port) do
    opts = Uniapp.SelfSigned.server_opts() ++ [versions: [:"tlsv1.3"], active: false, reuseaddr: true, mode: :binary, packet: :line]
    :ssl.listen(port, opts)
  end

  defp serve(:tcp, lsock) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    Task.start(fn -> tcp_loop(sock) end)
    serve(:tcp, lsock)
  end

  defp serve(:udp, sock) do
    case :gen_udp.recv(sock, 0) do
      {:ok, {addr, port, data}} -> :gen_udp.send(sock, addr, port, data)
      {:error, _} -> :ok
    end

    serve(:udp, sock)
  end

  defp serve(:tls, lsock) do
    with {:ok, tsock} <- :ssl.transport_accept(lsock),
         {:ok, sock} <- :ssl.handshake(tsock, 10_000) do
      Task.start(fn -> tls_loop(sock) end)
    else
      err -> Logger.warning("echo: tls accept failed: #{inspect(err)}")
    end

    serve(:tls, lsock)
  end

  defp tcp_loop(sock) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, data} -> :gen_tcp.send(sock, data); tcp_loop(sock)
      {:error, _} -> :gen_tcp.close(sock)
    end
  end

  defp tls_loop(sock) do
    case :ssl.recv(sock, 0) do
      {:ok, data} -> :ssl.send(sock, data); tls_loop(sock)
      {:error, _} -> :ssl.close(sock)
    end
  end
end
