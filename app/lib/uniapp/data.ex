defmodule Uniapp.Data do
  @moduledoc """
  Persistent state on the data volume. `/init` mounts an ext2 volume at
  `/data` (`uniapp.data=auto` on the kernel command line) and exports
  `UNIAPP_DATA=/data`; without it `dir/0` is `nil` and everything here is a
  no-op.

  The boot counter is the smoke test's proof of persistence: it survives
  `aws ec2 reboot-instances`. Writes go through `:file.sync/1`, because ext2
  has no journal and the kernel only flushes on unmount.
  """
  def dir, do: System.get_env("UNIAPP_DATA")

  @doc "Increments and returns the boot counter stored on the data volume."
  def bump_boot_counter do
    case dir() do
      nil ->
        IO.puts("DATA none")
        nil

      dir ->
        path = Path.join(dir, "boot_count")

        count =
          case File.read(path) do
            {:ok, s} -> s |> String.trim() |> Integer.parse() |> elem(0)
            _ -> 0
          end

        count = count + 1
        write_sync(path, Integer.to_string(count) <> "\n")
        IO.puts("DATA boot_count #{count} #{dir}")
        count
    end
  end

  @doc "Writes `content` to `path` and syncs it to the device."
  def write_sync(path, content) do
    {:ok, fd} = :file.open(String.to_charlist(path), [:write, :binary, :raw])
    :ok = :file.write(fd, content)
    :ok = :file.sync(fd)
    :ok = :file.close(fd)
  end
end
