defmodule Uniapp.Cmdline do
  @moduledoc """
  Access to kernel command-line parameters. `/init` copies `/proc/cmdline`
  into the environment variable `KERNEL_CMDLINE` before exec'ing beam.smp,
  so this works on kernels without procfs too.
  """

  def get(key, default \\ nil) do
    raw = System.get_env("KERNEL_CMDLINE") || read_proc()

    raw
    |> String.split()
    |> Enum.find_value(default, fn tok ->
      case String.split(tok, "=", parts: 2) do
        [^key, v] -> v
        _ -> nil
      end
    end)
  end

  defp read_proc do
    case File.read("/proc/cmdline") do
      {:ok, s} -> s
      _ -> ""
    end
  end
end
