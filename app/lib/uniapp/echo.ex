defmodule Uniapp.Echo do
  @moduledoc "Minimal TCP echo server: proves :gen_tcp listen/accept inside the image."
  use Task, restart: :permanent
  require Logger

  def start_link(opts), do: Task.start_link(__MODULE__, :run, [Keyword.fetch!(opts, :port)])

  def run(port) do
    {:ok, lsock} = :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true, ip: {0, 0, 0, 0}])
    Logger.info("echo: listening on tcp/#{port}")
    accept_loop(lsock)
  end

  defp accept_loop(lsock) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    Task.start(fn -> serve(sock) end)
    accept_loop(lsock)
  end

  defp serve(sock) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, data} ->
        :ok = :gen_tcp.send(sock, data)
        serve(sock)

      {:error, _} ->
        :gen_tcp.close(sock)
    end
  end
end
