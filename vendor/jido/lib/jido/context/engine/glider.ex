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
    span(:open, %{location: location_kind(location)}, fn ->
      guarded(fn ->
        case location do
          :memory -> apply(@glider, :open, [])
          {:file, path, sync} -> open_file(path, sync)
        end
      end)
    end)
  end

  defp location_kind(:memory), do: :memory
  defp location_kind({:file, _, sync}), do: {:file, sync}
  defp location_kind(other), do: other

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
  def run(db, statement) do
    span(:run, statement_metadata(statement), fn ->
      guarded(fn -> apply(@glider, :run, [db, statement]) end)
    end)
  end

  @impl true
  def query(db, statement) do
    span(:query, statement_metadata(statement), fn ->
      guarded(fn ->
        case apply(@glider, :query, [db, statement]) do
          {:ok, result} -> {:ok, %{columns: result.columns, rows: result.rows}}
          {:error, reason} -> {:error, reason}
        end
      end)
    end)
  end

  @impl true
  def export(db) do
    span(:export, %{}, fn -> guarded(fn -> apply(@glider, :export_jsonl, [db]) end) end)
  end

  @impl true
  def import(db, jsonl) do
    span(:import, %{bytes: byte_size(jsonl)}, fn ->
      guarded(fn -> apply(@glider, :import_jsonl, [db, jsonl]) end)
    end)
  end

  @impl true
  def checkpoint(db) do
    span(:checkpoint, %{}, fn -> guarded(fn -> apply(@glider, :checkpoint, [db]) end) end)
  end

  @impl true
  def stats(db) do
    span(:stats, %{}, fn -> guarded(fn -> apply(@glider, :stats, [db]) end) end)
  end

  @impl true
  def close(db) do
    if available?() do
      apply(@glider, :close, [db])
    else
      :ok
    end
  end

  # ===========================================================================
  # Instrumentation
  # ===========================================================================

  @doc """
  Telemetry emitted by this engine.

  Every call to the graph is wrapped in a `:telemetry.span/3`, so each one
  produces `[:jido, :context, :glider, <op>, :start | :stop | :exception]`.

  | Operation | Emitted for |
  |---|---|
  | `:open` | opening a graph, with `:location` |
  | `:query` | a read, with `:rows` returned |
  | `:run` | a write, with `:touched` entities |
  | `:import` / `:export` | bulk load and dump, with `:bytes` |
  | `:checkpoint` / `:stats` | flush and counters |

  `:stop` measurements always carry `:duration` (native units, as
  `:telemetry.span/3` produces) and metadata always carries `:result`, which is
  `:ok` or `:error` — a failed query is still a completed measurement, and
  counting it as one is the difference between "slow" and "broken" being
  visible separately.

  Queries additionally carry `:operation` — the leading Cypher keyword, upcased
  — and `:statement_bytes`. The keyword is the useful grouping dimension: it
  separates a `MATCH` costing milliseconds from a `CALL pagerank` costing
  seconds, without recording the statement text itself, which would put user
  data into telemetry.

  ## Why here rather than in the caller

  This is the only place every graph operation passes through. Instrumenting
  `Jido.Context.Graph` would miss direct engine use, and instrumenting inside
  Glider would mean measuring in Rust across a NIF boundary. The engine
  behaviour is the seam where a measurement is both complete and cheap.
  """
  @spec telemetry_events() :: [[atom()]]
  def telemetry_events do
    for op <- [:open, :query, :run, :import, :export, :checkpoint, :stats],
        suffix <- [:start, :stop, :exception] do
      [:jido, :context, :glider, op, suffix]
    end
  end

  defp span(op, metadata, fun) do
    :telemetry.span([:jido, :context, :glider, op], metadata, fn ->
      result = fun.()
      {result, Map.merge(metadata, result_metadata(result))}
    end)
  end

  # The shape of a result is the measurement worth keeping: how much came back,
  # and whether it worked at all.
  defp result_metadata({:ok, %{rows: rows}}) when is_list(rows),
    do: %{result: :ok, rows: length(rows)}

  defp result_metadata({:ok, touched}) when is_integer(touched),
    do: %{result: :ok, touched: touched}

  defp result_metadata({:ok, _}), do: %{result: :ok}
  defp result_metadata(:ok), do: %{result: :ok}
  defp result_metadata({:error, reason}), do: %{result: :error, error: reason}
  defp result_metadata(_), do: %{result: :ok}

  # The leading keyword, which is what distinguishes a cheap read from an
  # expensive algorithm. Deliberately not the statement itself: that can carry
  # entity keys and property values, which do not belong in telemetry metadata.
  defp statement_metadata(statement) when is_binary(statement) do
    operation =
      statement
      |> String.trim_leading()
      |> String.split(~r/\s/, parts: 2)
      |> List.first()
      |> to_string()
      |> String.upcase()

    %{operation: operation, statement_bytes: byte_size(statement)}
  end

  defp statement_metadata(_), do: %{operation: "UNKNOWN", statement_bytes: 0}

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
