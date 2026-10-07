defmodule Uniapp.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info(
      "uniapp starting (otp #{System.otp_release()}, elixir #{System.version()}, uptime #{uptime()}s)"
    )

    children = [
      Supervisor.child_spec({Uniapp.Echo, kind: :tcp, port: echo_port()}, id: :echo_tcp),
      Supervisor.child_spec({Uniapp.Echo, kind: :udp, port: echo_port() + 1}, id: :echo_udp),
      Supervisor.child_spec({Uniapp.Echo, kind: :tls, port: 4443}, id: :echo_tls),
      Uniapp.Probe
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Uniapp.Supervisor)
  end

  # Seconds since kernel boot, if the kernel exposes /proc/uptime.
  defp uptime do
    case File.read("/proc/uptime") do
      {:ok, s} -> s |> String.split() |> hd()
      _ -> "?"
    end
  end

  # Overridable for host-side testing where 4000 may be taken.
  def echo_port, do: String.to_integer(System.get_env("UNIAPP_ECHO_PORT") || "4000")
end
