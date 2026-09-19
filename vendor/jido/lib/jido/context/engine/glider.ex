defmodule Jido.Context.Engine.Glider do
  @moduledoc """
  `Jido.Context.Engine` backed by [Glider](https://github.com/agentjido/glider).

  Glider is an embedded property graph in the shape SQLite took for relational
  data: one file, no server, linked into the BEAM as a NIF. The graph is
  memory-resident and the file is its write-ahead log, so reads never touch
  disk and writes append.

  ## Installation

  Glider is not a dependency of Jido — it is a Rustler NIF and building it needs
  a Rust toolchain, which is not a cost every Jido application should pay. Add
  it to your own deps to turn `Jido.Context` on:

      {:glider_ex, "~> 0.1"}

  Without it every call here returns `{:error, :engine_unavailable}`.

  ## Serialisation

  Calls against one Glider handle are serialised by a mutex inside the NIF —
  Glider mutates an in-memory graph in place, so concurrent access would be a
  data race. `Jido.Context.Graph` owns one handle per graph and is the only
  caller, which satisfies that without contending on the mutex.

  Long-running calls (queries, algorithms, import, export, compaction) run on
  dirty schedulers, so a PageRank over a large graph does not stall the VM.
  """

  @behaviour Jido.Context.Engine

  @install_hint """
  Jido.Context needs the Glider graph engine, which is an optional dependency.

  Add it to your deps and recompile:

      {:glider_ex, "~> 0.1"}

  Building it requires a Rust toolchain (https://rustup.rs).
  """

  # Every call below goes through `apply/3` rather than naming `Glider`
  # directly. Not cosmetic: a direct call makes the compiler resolve the module,
  # so any build without the optional dependency emits "module Glider is not
  # available" for each call site and a release compiled with
  # --warnings-as-errors fails outright. Neither a module attribute nor a
  # private function helps -- the compiler folds both back into a literal call.
  @glider :"Elixir.Glider"

  @impl true
  def available?, do: Code.ensure_loaded?(@glider)

  @doc """
  The reason returned by every call when Glider is missing, with install
  instructions attached.
  """
  @spec install_hint() :: String.t()
  def install_hint, do: @install_hint

  @impl true
  def open(location) do
    guarded(fn ->
      case location do
        :memory -> apply(@glider, :open, [])
        {:file, path, sync} -> open_file(path, sync)
      end
    end)
  end

  defp open_file(path, sync) do
    with :ok <- ensure_parent_dir(path) do
      apply(@glider, :open, [path, sync])
    end
  end

  defp ensure_parent_dir(path) do
    case path |> Path.dirname() |> File.mkdir_p() do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir, reason}}
    end
  end

  @impl true
  def run(db, statement), do: guarded(fn -> apply(@glider, :run, [db, statement]) end)

  @impl true
  def query(db, statement) do
    guarded(fn ->
      case apply(@glider, :query, [db, statement]) do
        {:ok, result} -> {:ok, %{columns: result.columns, rows: result.rows}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def export(db), do: guarded(fn -> apply(@glider, :export_jsonl, [db]) end)

  @impl true
  def import(db, jsonl), do: guarded(fn -> apply(@glider, :import_jsonl, [db, jsonl]) end)

  @impl true
  def checkpoint(db), do: guarded(fn -> apply(@glider, :checkpoint, [db]) end)

  @impl true
  def stats(db), do: guarded(fn -> apply(@glider, :stats, [db]) end)

  @impl true
  def close(db) do
    if available?() do
      apply(@glider, :close, [db])
    else
      :ok
    end
  end

  # Glider is resolved at runtime, so every entry point checks first rather
  # than letting an application without the optional dependency fail with an
  # UndefinedFunctionError from somewhere deep in a GenServer callback.
  defp guarded(fun) do
    if available?() do
      fun.()
    else
      {:error, {:engine_unavailable, @install_hint}}
    end
  end
end
