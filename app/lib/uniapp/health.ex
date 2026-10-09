defmodule Uniapp.Health do
  @moduledoc """
  A tiny HTTP/1.1 health endpoint for load balancers and auto-scaling groups,
  on port 8080 by default (`uniapp.health_port=`), pure Elixir on `:gen_tcp`.

    * `GET /healthz`  200 `{"status":"ok", ...}` once every echo server
      listens, 503 `{"status":"starting"}` before. Body carries uptime,
      BEAM memory, process count, instance id, boot count and the TCP echo
      throughput measured by `Uniapp.Health.bench/0` (bytes per second
      through the loopback echo, a cheap self-test of the network stack).
    * `GET /livez`    200 as soon as the socket is open (the VM is alive).
    * anything else   404.

  ALB: health check path `/healthz`, port 8080, matcher 200. ASG: health
  check type ELB. One request per second per target is a few hundred
  microseconds of work here.
  """
  use Task, restart: :permanent
  import Bitwise, only: [<<<: 2]
  require Logger

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def port, do: String.to_integer(Uniapp.Cmdline.get("uniapp.health_port", "8080"))

  def run do
    case :gen_tcp.listen(port(), [:binary, packet: :http_bin, active: false, reuseaddr: true, backlog: 64]) do
      {:ok, lsock} ->
        Logger.info("health: listening http/#{port()}")
        IO.puts("LISTEN http #{port()}")
        accept(lsock)

      {:error, reason} ->
        Logger.error("health: listen failed: #{inspect(reason)}; retrying in 5s")
        Process.sleep(5_000)
        run()
    end
  end

  defp accept(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} -> Task.start(fn -> handle(sock) end)
      {:error, reason} -> Logger.warning("health: accept: #{inspect(reason)}")
    end

    accept(lsock)
  end

  defp handle(sock) do
    with {:ok, {:http_request, method, {:abs_path, path}, _}} <- :gen_tcp.recv(sock, 0, 5_000),
         :ok <- drain_headers(sock) do
      {status, body} = respond(method, path)
      json = JSON.encode!(body)

      :gen_tcp.send(sock, [
        "HTTP/1.1 #{status} #{reason(status)}\r\n",
        "Content-Type: application/json\r\nContent-Length: #{byte_size(json)}\r\nConnection: close\r\n",
        "Cache-Control: no-store\r\n\r\n",
        json
      ])
    end

    :gen_tcp.close(sock)
  end

  defp drain_headers(sock) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _, _, _, _}} -> drain_headers(sock)
      {:ok, _} -> drain_headers(sock)
      {:error, _} = e -> e
    end
  end

  defp respond(:GET, "/livez"), do: {200, %{"status" => "alive"}}
  defp respond(:HEAD, "/livez"), do: {200, %{}}

  defp respond(m, "/healthz") when m in [:GET, :HEAD] do
    if ready?() do
      {200, Map.merge(%{"status" => "ok"}, details())}
    else
      {503, %{"status" => "starting", "listening" => listening()}}
    end
  end

  defp respond(_, _), do: {404, %{"error" => "not found"}}

  # Ready when every echo server has its listen socket (they log LISTEN lines).
  def ready?, do: Enum.all?([:tcp, :udp, :tls], &(&1 in listening()))

  def listening, do: Uniapp.Echo.listening()

  defp details do
    %{
      "uptime_s" => div(:erlang.monotonic_time() - :erlang.system_info(:start_time), 1_000_000_000),
      "memory_bytes" => :erlang.memory(:total),
      "processes" => :erlang.system_info(:process_count),
      "schedulers" => :erlang.system_info(:schedulers_online),
      "instance_id" => System.get_env("EC2_INSTANCE_ID"),
      "boot_count" => Uniapp.Data.boot_count(),
      "echo_bench_bytes_per_s" => bench_cached()
    }
  end

  @doc """
  Pushes `bytes` through the TCP echo server over the NIC address (loopback
  on Asterinas does not reach a 0.0.0.0 listener, see patch 0001) and returns
  bytes per second, or nil. Measures the network stack and NIC driver
  loopback path, not the wire.
  """
  def bench(bytes \\ 8 * 1024 * 1024) do
    with {:ok, addr} <- nic_addr(),
         {:ok, sock} <- :gen_tcp.connect(addr, Uniapp.Application.echo_port(), [:binary, active: false, packet: 0, sndbuf: 1 <<< 20, recbuf: 1 <<< 20], 5_000) do
      line = :binary.copy(<<"x">>, 1023) <> "\n"
      n = div(bytes, byte_size(line))
      t0 = System.monotonic_time(:microsecond)
      sender = Task.async(fn -> Enum.each(1..n, fn _ -> :gen_tcp.send(sock, line) end) end)
      received = recv_all(sock, n * byte_size(line), 0)
      Task.await(sender, 60_000)
      dt = System.monotonic_time(:microsecond) - t0
      :gen_tcp.close(sock)
      bps = div(received * 1_000_000, max(dt, 1))
      :persistent_term.put({__MODULE__, :bench}, bps)
      IO.puts("BENCH tcp_echo #{received} bytes in #{div(dt, 1000)} ms = #{div(bps, 1_000_000)} MB/s")
      {:ok, bps}
    else
      err -> {:error, err}
    end
  end

  defp recv_all(_sock, want, got) when got >= want, do: got

  defp recv_all(sock, want, got) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> recv_all(sock, want, got + byte_size(data))
      {:error, _} -> got
    end
  end

  defp bench_cached, do: :persistent_term.get({__MODULE__, :bench}, nil)

  defp nic_addr do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        ifs
        |> Enum.reject(fn {name, _} -> name in [~c"lo", ~c"lo0"] end)
        |> Enum.flat_map(fn {_, opts} -> for {:addr, {_, _, _, _} = a} <- opts, do: a end)
        |> case do
          [a | _] -> {:ok, a}
          [] -> {:error, :no_nic}
        end

      err ->
        err
    end
  end

  defp reason(200), do: "OK"
  defp reason(404), do: "Not Found"
  defp reason(503), do: "Service Unavailable"
end
