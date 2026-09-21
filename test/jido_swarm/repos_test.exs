defmodule JidoSwarm.ReposTest do
  @moduledoc """
  Containment tests for the repository layer.

  A model supplies the paths these functions receive, so "cannot write outside
  the clone" has to be a property of the code rather than of the prompt.
  """

  use ExUnit.Case, async: true

  alias JidoSwarm.Repos

  setup do
    root = Path.join(System.tmp_dir!(), "swarm_repos_test_#{System.unique_integer([:positive])}")
    repo = %{name: "demo", url: nil, source: nil, default_branch: "main", test_command: "true",
             description: ""}

    File.mkdir_p!(Path.join(root, "demo"))
    previous = Application.get_env(:jido_swarm, Repos, [])
    Application.put_env(:jido_swarm, Repos, Keyword.put(previous, :workspace, root))

    on_exit(fn ->
      Application.put_env(:jido_swarm, Repos, previous)
      File.rm_rf(root)
    end)

    {:ok, repo: repo, root: root}
  end

  describe "safe_path/2" do
    test "resolves a path inside the clone", %{repo: repo} do
      assert {:ok, path} = Repos.safe_path(repo, "lib/thing.ex")
      assert String.ends_with?(path, "/demo/lib/thing.ex")
    end

    test "allows the repository root itself", %{repo: repo} do
      assert {:ok, _} = Repos.safe_path(repo, ".")
    end

    test "refuses a traversal", %{repo: repo} do
      assert {:error, {:path_escapes_repo, _}} = Repos.safe_path(repo, "../escape.ex")
      assert {:error, {:path_escapes_repo, _}} = Repos.safe_path(repo, "lib/../../escape.ex")
      assert {:error, {:path_escapes_repo, _}} = Repos.safe_path(repo, "../../etc/passwd")
    end

    test "refuses an absolute path rather than silently relocating it", %{repo: repo} do
      assert {:error, {:absolute_path, "/etc/passwd"}} = Repos.safe_path(repo, "/etc/passwd")
    end

    test "refuses a sibling directory that merely shares a prefix", %{repo: repo, root: root} do
      # `<root>/demo-evil` starts with `<root>/demo` as a string but is not
      # inside it — a prefix check without the separator would let this through.
      assert {:error, {:path_escapes_repo, _}} = Repos.safe_path(repo, "../demo-evil/x.ex")
      refute File.exists?(Path.join(root, "demo-evil"))
    end
  end

  describe "write_file/3" do
    test "writes inside the clone and creates parents", %{repo: repo, root: root} do
      assert :ok = Repos.write_file(repo, "lib/nested/thing.ex", "hello")
      assert File.read!(Path.join([root, "demo", "lib", "nested", "thing.ex"])) == "hello"
    end

    test "refuses to write outside the clone", %{repo: repo, root: root} do
      assert {:error, {:path_escapes_repo, _}} = Repos.write_file(repo, "../escaped.ex", "bad")
      refute File.exists?(Path.join(root, "escaped.ex"))
    end
  end

  describe "read_file/3" do
    test "truncates a large file rather than returning all of it", %{repo: repo} do
      :ok = Repos.write_file(repo, "big.txt", String.duplicate("x", 10_000))

      assert {:ok, content} = Repos.read_file(repo, "big.txt", 100)
      assert content =~ "truncated"
      assert byte_size(content) < 200
    end

    test "is an error for a missing file", %{repo: repo} do
      assert {:error, :enoent} = Repos.read_file(repo, "nope.txt")
    end
  end

  describe "repo_slug/1" do
    test "parses an https URL" do
      assert {:ok, "djcarpe/glider"} =
               Repos.repo_slug(%{url: "https://github.com/djcarpe/glider.git"})
    end

    test "parses an ssh URL" do
      assert {:ok, "djcarpe/glider"} = Repos.repo_slug(%{url: "git@github.com:djcarpe/glider.git"})
    end

    test "is :error without a URL" do
      assert :error = Repos.repo_slug(%{url: nil})
    end
  end

  describe "publishing readiness" do
    test "can_publish?/0 follows GITHUB_TOKEN" do
      System.delete_env("GITHUB_TOKEN")
      refute Repos.can_publish?()

      System.put_env("GITHUB_TOKEN", "ghp_test")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)
      assert Repos.can_publish?()
    end

    test "push/2 refuses without a token", %{repo: repo} do
      System.delete_env("GITHUB_TOKEN")
      assert {:error, :no_github_token} = Repos.push(repo, "some-branch")
    end
  end
end
