defmodule Uniapp.Cloudwatch do
  @moduledoc """
  Ships the node's log to CloudWatch Logs and publishes metrics without any
  agent: the image has no room for one, so the application signs the requests
  itself.

    * Logger handler: every log event is buffered and flushed to
      `PutLogEvents` every 5 s (or 100 events). Log group `uniapp.log_group`
      (default `/elixir_unikernel`), stream = the instance id.
    * Metrics: `metric/3` emits Embedded Metric Format (EMF) JSON lines into
      the same stream; CloudWatch derives metrics from them, no `PutMetricData`
      needed. Namespace `uniapp.metric_namespace` (default `elixir_unikernel`).
    * A heartbeat every 60 s publishes `Uptime`, `MemoryTotal` (BEAM bytes)
      and `ProcessCount`.

  Credentials come from the instance role via IMDSv2 (`/init` left the token
  in `EC2_IMDS_TOKEN`, the region in `AWS_REGION`); they are refreshed when
  within 5 minutes of expiry. SigV4 is implemented here with `:crypto`.
  Enabled when `uniapp.cloudwatch=1` (command line or user data) and the
  instance has a role; otherwise `start_link/1` returns `:ignore`.
  """
  use GenServer

  @imds "http://169.254.169.254/latest"
  @flush_ms 5_000
  @heartbeat_ms 60_000
  @max_batch 100

  # ---------------------------------------------------------------- public

  def start_link(_opts) do
    if enabled?() do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    else
      :ignore
    end
  end

  def enabled?, do: Uniapp.Cmdline.get("uniapp.cloudwatch") in ["1", "on", "true"]

  @doc "Records an EMF metric. `unit` as in CloudWatch (\"Count\", \"Seconds\", \"Bytes\", ...)."
  def metric(name, value, unit \\ "Count", dimensions \\ %{}) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:metric, name, value, unit, dimensions})
    :ok
  end

  # Erlang `logger` handler callback: called for every log event.
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    if pid = Process.whereis(__MODULE__) do
      text = format_msg(msg)
      ts = Map.get(meta, :time, :os.system_time(:microsecond)) |> div(1000)
      send(pid, {:log, ts, "[#{level}] #{text}"})
    end

    :ok
  end

  # ---------------------------------------------------------------- server

  @impl true
  def init(_) do
    region = System.get_env("AWS_REGION") || raise "AWS_REGION not set (needs uniapp.imds=1)"
    instance = System.get_env("EC2_INSTANCE_ID") || "unknown"
    group = Uniapp.Cmdline.get("uniapp.log_group", "/elixir_unikernel")
    namespace = Uniapp.Cmdline.get("uniapp.metric_namespace", "elixir_unikernel")

    state = %{
      region: region,
      host: "logs.#{region}.amazonaws.com",
      group: group,
      stream: instance,
      instance: instance,
      namespace: namespace,
      creds: nil,
      buffer: [],
      stream_ready: false
    }

    :ok = :logger.add_handler(:uniapp_cloudwatch, __MODULE__, %{level: :info})
    Process.send_after(self(), :flush, @flush_ms)
    Process.send_after(self(), :heartbeat, 5_000)
    IO.puts("CLOUDWATCH #{group} #{instance} #{region}")
    {:ok, state}
  end

  @impl true
  def handle_info({:log, ts, line}, state) do
    # Flushing happens on the timer only; a burst just grows the buffer briefly.
    {:noreply, %{state | buffer: Enum.take([{ts, line} | state.buffer], 5 * @max_batch)}}
  end

  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_ms)
    # A shipping failure must never take the application down.
    state =
      try do
        flush(state)
      rescue
        e -> IO.puts(:stderr, "cloudwatch: flush failed: #{Exception.message(e)}"); %{state | buffer: Enum.take(state.buffer, 1000)}
      catch
        kind, reason -> IO.puts(:stderr, "cloudwatch: flush failed: #{inspect({kind, reason})}"); %{state | buffer: Enum.take(state.buffer, 1000)}
      end

    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    uptime = div(:erlang.monotonic_time() - :erlang.system_info(:start_time), 1_000_000_000)
    state = emf(state, [{"Uptime", uptime, "Seconds"}, {"MemoryTotal", :erlang.memory(:total), "Bytes"}, {"ProcessCount", :erlang.system_info(:process_count), "Count"}], %{})
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_cast({:metric, name, value, unit, dims}, state) do
    {:noreply, emf(state, [{name, value, unit}], dims)}
  end

  # ---------------------------------------------------------------- EMF

  defp emf(state, metrics, dims) do
    dims = Map.merge(%{"InstanceId" => state.instance}, stringify(dims))
    now = :os.system_time(:millisecond)

    doc =
      %{
        "_aws" => %{
          "Timestamp" => now,
          "CloudWatchMetrics" => [
            %{
              "Namespace" => state.namespace,
              "Dimensions" => [Map.keys(dims)],
              "Metrics" => Enum.map(metrics, fn {n, _v, u} -> %{"Name" => n, "Unit" => u} end)
            }
          ]
        }
      }
      |> Map.merge(dims)
      |> Map.merge(Map.new(metrics, fn {n, v, _u} -> {n, v} end))

    %{state | buffer: [{now, json(doc)} | state.buffer]}
  end

  # ---------------------------------------------------------------- flush

  defp flush(%{buffer: []} = state), do: state

  defp flush(state) do
    with {:ok, state} <- ensure_creds(state),
         {:ok, state} <- ensure_stream(state) do
      events =
        state.buffer
        |> Enum.reverse()
        |> Enum.sort_by(fn {ts, _} -> ts end)
        |> Enum.map(fn {ts, msg} -> %{"timestamp" => ts, "message" => String.slice(msg, 0, 256_000)} end)

      body = json(%{"logGroupName" => state.group, "logStreamName" => state.stream, "logEvents" => events})

      case call(state, "Logs_20140328.PutLogEvents", body) do
        {:ok, _} -> %{state | buffer: []}
        {:error, {:http, 400, resp}} = err ->
          if is_binary(resp) and resp =~ "DataAlreadyAcceptedException" do
            %{state | buffer: []}
          else
            IO.puts(:stderr, "cloudwatch: PutLogEvents failed: #{inspect(err)}")
            %{state | buffer: Enum.take(state.buffer, 1000)}
          end

        {:error, reason} ->
          IO.puts(:stderr, "cloudwatch: PutLogEvents failed: #{inspect(reason)}")
          # Keep at most 1000 events while the endpoint is unreachable.
          %{state | buffer: Enum.take(state.buffer, 1000)}
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, "cloudwatch: #{inspect(reason)}")
        %{state | buffer: Enum.take(state.buffer, 1000)}
    end
  end

  defp ensure_stream(%{stream_ready: true} = state), do: {:ok, state}

  defp ensure_stream(state) do
    _ = call(state, "Logs_20140328.CreateLogGroup", json(%{"logGroupName" => state.group}))

    case call(state, "Logs_20140328.CreateLogStream", json(%{"logGroupName" => state.group, "logStreamName" => state.stream})) do
      {:ok, _} -> {:ok, %{state | stream_ready: true}}
      {:error, {:http, 400, resp}} = err ->
        if is_binary(resp) and resp =~ "ResourceAlreadyExistsException",
          do: {:ok, %{state | stream_ready: true}},
          else: {:error, {:create_stream, err}}

      {:error, reason} -> {:error, {:create_stream, reason}}
    end
  end

  # ---------------------------------------------------------------- credentials (IMDSv2)

  defp ensure_creds(%{creds: %{expires: exp} = _} = state) when is_integer(exp) do
    if exp - System.os_time(:second) > 300, do: {:ok, state}, else: fetch_creds(state)
  end

  defp ensure_creds(state), do: fetch_creds(state)

  defp fetch_creds(state) do
    token = System.get_env("EC2_IMDS_TOKEN")
    hdr = [{~c"X-aws-ec2-metadata-token", String.to_charlist(token || "")}]

    with {:ok, role} <- http_get("#{@imds}/meta-data/iam/security-credentials/", hdr),
         role when role != "" <- String.trim(role),
         {:ok, body} <- http_get("#{@imds}/meta-data/iam/security-credentials/#{role}", hdr),
         %{"AccessKeyId" => ak, "SecretAccessKey" => sk, "Token" => st, "Expiration" => exp} <- JSON.decode!(body) do
      {:ok, %{state | creds: %{access_key: ak, secret: sk, session: st, expires: iso_to_unix(exp)}}}
    else
      "" -> {:error, :no_instance_role}
      other -> {:error, {:imds_credentials, other}}
    end
  end

  defp iso_to_unix(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> System.os_time(:second) + 3600
    end
  end

  # ---------------------------------------------------------------- HTTP + SigV4

  defp call(state, target, body) do
    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = Calendar.strftime(now, "%Y%m%d")
    c = state.creds

    headers = [
      {"content-type", "application/x-amz-json-1.1"},
      {"host", state.host},
      {"x-amz-date", amz_date},
      {"x-amz-security-token", c.session},
      {"x-amz-target", target}
    ]

    signed_headers = headers |> Enum.map(&elem(&1, 0)) |> Enum.join(";")
    canonical_headers = headers |> Enum.map(fn {k, v} -> "#{k}:#{v}\n" end) |> Enum.join()
    payload_hash = sha256_hex(body)
    canonical = Enum.join(["POST", "/", "", canonical_headers, signed_headers, payload_hash], "\n")
    scope = "#{date}/#{state.region}/logs/aws4_request"
    to_sign = Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, sha256_hex(canonical)], "\n")

    signing_key =
      ("AWS4" <> c.secret)
      |> hmac(date)
      |> hmac(state.region)
      |> hmac("logs")
      |> hmac("aws4_request")

    signature = signing_key |> hmac(to_sign) |> Base.encode16(case: :lower)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{c.access_key}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    req_headers =
      (headers ++ [{"authorization", auth}])
      |> Enum.reject(fn {k, _} -> k in ["host", "content-type"] end)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    url = String.to_charlist("https://#{state.host}/")

    case :httpc.request(:post, {url, req_headers, ~c"application/x-amz-json-1.1", body}, [timeout: 10_000, ssl: ssl_opts(state.host)], body_format: :binary) do
      {:ok, {{_, 200, _}, _, resp}} -> {:ok, resp}
      {:ok, {{_, code, _}, _, resp}} -> {:error, {:http, code, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ssl_opts(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp http_get(url, headers) do
    case :httpc.request(:get, {String.to_charlist(url), headers}, [timeout: 3_000, ssl: []], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, code, _}, _, body}} -> {:error, {:http, code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp json(term), do: JSON.encode!(term)
  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)

  defp format_msg({:string, s}), do: IO.chardata_to_string(s)
  defp format_msg({:report, r}), do: inspect(r)
  defp format_msg({fmt, args}) when is_list(fmt) or is_binary(fmt), do: :io_lib.format(fmt, args) |> IO.chardata_to_string()
  defp format_msg(other), do: inspect(other)
end
