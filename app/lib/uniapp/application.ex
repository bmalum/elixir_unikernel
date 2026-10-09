defmodule Uniapp.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info(
      "uniapp starting (otp #{System.otp_release()}, elixir #{System.version()}, uptime #{uptime()}s)"
    )

    boot_count = Uniapp.Data.bump_boot_counter()

    children = [
      Uniapp.Cloudwatch,
      Supervisor.child_spec({Uniapp.Echo, kind: :tcp, port: echo_port()}, id: :echo_tcp),
      Supervisor.child_spec({Uniapp.Echo, kind: :udp, port: echo_port() + 1}, id: :echo_udp),
      Supervisor.child_spec({Uniapp.Echo, kind: :tls, port: 4443}, id: :echo_tls),
      Uniapp.Probe
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Uniapp.Supervisor)
    if boot_count, do: Uniapp.Cloudwatch.metric("BootCount", boot_count)
    halt_after_first_boot(boot_count)
    result
  end

  # Test hook for the restart path: `uniapp.halt_after_first_boot=MS` stops the
  # VM MS milliseconds into the first boot of a data volume (boot_count 1) and
  # never again, so a smoke test can watch /init reboot the machine once.
  defp halt_after_first_boot(1) do
    case Uniapp.Cmdline.get("uniapp.halt_after_first_boot") do
      nil -> :ok
      ms -> :timer.apply_after(String.to_integer(ms), :erlang, :halt, [0])
    end
  end

  defp halt_after_first_boot(_), do: :ok

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
