defmodule Uniapp.ReleaseSteps do
  @moduledoc """
  Post-assemble pruning of the release: removes everything the shell-free
  boot does not need. Keeps the result honest w.r.t. GOALS.md criterion 5.
  """

  def prune(%Mix.Release{path: path} = rel) do
    erts = Path.wildcard(Path.join(path, "erts-*")) |> hd()
    bin = Path.join(erts, "bin")

    # ERTS bin: keep only beam.smp and erl_child_setup.
    for f <- File.ls!(bin), f not in ["beam.smp", "erl_child_setup"] do
      File.rm_rf!(Path.join(bin, f))
    end

    # Release bin/ (bin/uniapp shell script) and vm.args are unused.
    File.rm_rf!(Path.join(path, "bin"))

    # Remove sources, includes, docs, C sources and dynamic NIF leftovers.
    for pat <- ~w(lib/*/src lib/*/include lib/*/doc lib/*/c_src lib/*/examples lib/*/priv/lib lib/*/priv/obj
                  erts-*/include erts-*/src erts-*/doc erts-*/man erts-*/lib) do
      path |> Path.join(pat) |> Path.wildcard() |> Enum.each(&File.rm_rf!/1)
    end

    # The interactive shell needs a terminfo-free TERM; nothing else to keep.
    rel
  end
end
