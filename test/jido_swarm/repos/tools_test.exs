defmodule JidoSwarm.Repos.ToolsTest do
  use ExUnit.Case, async: false

  alias JidoSwarm.Repos.Tools

  # A tiny repository in the workspace, so the tools go through the same path
  # containment the real clones do.
  setup do
    name = "toolrepo_#{System.unique_integer([:positive])}"
    root = JidoSwarm.Repos.path(name)
    File.mkdir_p!(Path.join(root, "lib/deep"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "README.md"), "# Tool repo\n\nhello\n")

    File.write!(
      Path.join(root, "lib/a.ex"),
      Enum.map_join(1..300, "\n", &"line #{&1} needle#{rem(&1, 100)}")
    )

    File.write!(Path.join(root, "lib/deep/b.ex"), "defmodule B do\n  # needle0 here\nend\n")
    File.write!(Path.join(root, ".git/config"), "secret")
    on_exit(fn -> File.rm_rf!(root) end)

    repo = %{
      name: name,
      url: nil,
      source: nil,
      default_branch: "main",
      test_command: "true",
      description: ""
    }

    {:ok, repos: [repo], name: name}
  end

  test "list_files lists the clone, never .git, with an optional glob", %{
    repos: repos,
    name: name
  } do
    listed = Tools.call("list_files", %{"repo" => name}, repos)
    assert listed == "README.md\nlib/a.ex\nlib/deep/b.ex"

    assert Tools.call("list_files", %{"repo" => name, "glob" => "lib/**/*.ex"}, repos) ==
             "lib/a.ex\nlib/deep/b.ex"

    assert Tools.call("list_files", %{"repo" => name, "glob" => "../**"}, repos) =~ "outside"
  end

  test "read_file returns numbered lines and windows", %{repos: repos, name: name} do
    text = Tools.call("read_file", %{"repo" => name, "path" => "lib/a.ex", "lines" => 2}, repos)
    assert text =~ "lib/a.ex (lines 1–2 of 300)"
    assert text =~ "1: line 1 needle1\n2: line 2 needle2"
    assert text =~ "298 more lines; read from start_line 3"

    later =
      Tools.call(
        "read_file",
        %{"repo" => name, "path" => "lib/a.ex", "start_line" => "299", "lines" => 5},
        repos
      )

    assert later =~ "299: line 299" and later =~ "300: line 300"
    refute later =~ "more lines"

    assert Tools.call("read_file", %{"repo" => name, "path" => "nope.ex"}, repos) =~
             "No file at nope.ex"

    assert Tools.call("read_file", %{"repo" => name, "path" => "../../etc/passwd"}, repos) =~
             "outside"

    assert Tools.call("read_file", %{"repo" => name, "path" => "/etc/passwd"}, repos) =~
             "absolute"

    assert Tools.call("read_file", %{"repo" => name, "path" => ".git/config"}, repos) =~ "secret"
  end

  test "grep returns path:line matches, narrowed by a glob", %{repos: repos, name: name} do
    hits = Tools.call("grep", %{"repo" => name, "pattern" => "needle0\\b"}, repos)
    assert hits =~ "lib/a.ex:100: line 100 needle0"
    assert hits =~ "lib/deep/b.ex:2:   # needle0 here"

    only =
      Tools.call(
        "grep",
        %{"repo" => name, "pattern" => "needle0", "glob" => "lib/deep/*.ex"},
        repos
      )

    refute only =~ "lib/a.ex"

    assert Tools.call("grep", %{"repo" => name, "pattern" => "zzz"}, repos) =~ "No matches"

    assert Tools.call("grep", %{"repo" => name, "pattern" => "("}, repos) =~
             "not a valid regular expression"
  end

  test "the wrong repository or tool is a sentence, not a crash", %{repos: repos} do
    assert Tools.call("read_file", %{"repo" => "other", "path" => "x"}, repos) =~
             "No repository named \"other\""

    assert Tools.call("read_file", %{"path" => "x"}, repos) =~ "Say which repository"
    assert Tools.call("format_disk", %{"repo" => hd(repos).name}, repos) =~ "No such tool"
  end
end
