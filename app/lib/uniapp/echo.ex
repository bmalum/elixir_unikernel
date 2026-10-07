defmodule Uniapp.Echo do
  @moduledoc """
  Minimal TCP echo server: proves :gen_tcp listen/accept inside the image.
  A failing listen is logged and retried instead of crashing the supervisor
  (on a new kernel a missing socket feature must not take the whole VM down).
  """
  use Task, restart: :permanent
  require Logger

  def start_link(opts), do: Task.start_link(__MODULE__, :run, [Keyword.fetch!(opts, :port)])

  def run(port) do
    case :gen_tcp.listen(port, [:binary, packet: :line, active: false, reuseaddr: true]) do
      {:ok, lsock} ->
        Logger.info("echo: listening on tcp/#{port}")
        accept_loop(lsock)

      {:error, reason} ->
        Logger.error("echo: listen on tcp/#{port} failed: #{inspect(reason)}; retrying in 5s")
        Process.sleep(5_000)
        run(port)
    end
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
