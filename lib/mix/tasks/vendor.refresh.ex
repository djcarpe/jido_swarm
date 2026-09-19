defmodule Mix.Tasks.Vendor.Refresh do
  @shortdoc "Re-syncs vendor/ from the local working checkouts"

  @moduledoc """
  Re-syncs the vendored trees under `vendor/` from your working checkouts.

      $ mix vendor.refresh
      $ mix vendor.refresh --ref worktree-context-glider-mesh
      $ mix vendor.refresh jido

  ## Why these are vendored at all

  `jido` is carried at a branch with unreleased `Jido.Context` work, and
  `glider` / `glider_ex` are not on Hex. A path dependency pointing straight at
  `/home/dj/Work/...` would work on this machine and nowhere else — least of all
  inside a container, where the build context cannot reach outside the project.
  Vendoring keeps the image build self-contained and the dependency explicit.

  Content comes from `git archive`, so only committed files are copied:
  uncommitted work in your checkout is deliberately *not* picked up. Commit
  first, then refresh.

  ## Options

  * `--ref REF` — the ref to archive from every repository. Defaults to `HEAD`.
  * `--source DIR` — where the checkouts live. Defaults to the parent of this
    project.
  """

  use Mix.Task

  @vendored ~w(jido glider glider_ex)

  @impl Mix.Task
  def run(argv) do
    {opts, names, _} = OptionParser.parse(argv, strict: [ref: :string, source: :string])

    ref = Keyword.get(opts, :ref, "HEAD")
    source_root = Keyword.get(opts, :source, Path.expand("..", File.cwd!()))
    targets = if names == [], do: @vendored, else: names

    Enum.each(targets, &refresh(&1, source_root, ref))

    Mix.shell().info("""

    Vendored trees refreshed. Rebuild the dependencies so the change takes effect:

        mix deps.compile jido glider_ex --force
    """)
  end

  defp refresh(name, source_root, ref) do
    source = Path.join(source_root, name)
    dest = Path.join([File.cwd!(), "vendor", name])

    unless File.dir?(Path.join(source, ".git")) do
      Mix.raise("#{source} is not a git checkout — pass --source to say where the repos live")
    end

    File.rm_rf!(dest)
    File.mkdir_p!(dest)

    archive(source, ref, dest)
    strip_build_output(dest)

    Mix.shell().info("  vendored #{name} from #{source} at #{ref}")
  end

  # `git archive | tar -x` rather than a copy, so ignored files and build output
  # never enter the image context in the first place.
  defp archive(source, ref, dest) do
    {archive, 0} = System.cmd("git", ["archive", "--format=tar", ref], cd: source)
    tmp = Path.join(System.tmp_dir!(), "vendor-#{System.unique_integer([:positive])}.tar")

    try do
      File.write!(tmp, archive)
      {_, 0} = System.cmd("tar", ["-x", "-f", tmp, "-C", dest])
    after
      File.rm(tmp)
    end
  end

  # Some of these repositories commit a `target/` or a prebuilt artifact. The
  # image builds its own, and shipping theirs would add tens of megabytes of
  # dead weight to the build context.
  defp strip_build_output(dest) do
    for path <- ["_build", "deps", "target", "native/glider_nif/target", "tmp"] do
      dest |> Path.join(path) |> File.rm_rf()
    end
  end
end
