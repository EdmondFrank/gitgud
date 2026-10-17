defmodule GitGud.MCP.ToolsTest do
  @moduledoc """
  Unit tests for the `GitGud.MCP.Tools.*` read-only tools (see `guides/MCP.md` §11, Phase 3).

  Tools are pure functions of `(params, frame)`; the authenticated user is
  supplied through `frame.assigns[:current_user]`, mirroring how Anubis merges
  `Plug.Conn.assigns` into the tool frame at runtime.
  """

  use GitGud.Web.ConnCase, async: false
  use GitGud.Web.DataFactory

  alias Anubis.Server.Frame

  alias GitGud.Issue
  alias GitGud.Release
  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.User

  alias GitGud.MCP.Tools.GetCommit
  alias GitGud.MCP.Tools.GetIssue
  alias GitGud.MCP.Tools.GetRepository
  alias GitGud.MCP.Tools.GetTree
  alias GitGud.MCP.Tools.ListBranches
  alias GitGud.MCP.Tools.ListIssueComments
  alias GitGud.MCP.Tools.ListIssues
  alias GitGud.MCP.Tools.ListReleases
  alias GitGud.MCP.Tools.ListTags
  alias GitGud.MCP.Tools.ReadFile
  alias GitGud.MCP.Tools.Search
  alias GitGud.MCP.Tools.SearchRepositories
  alias GitGud.MCP.Tools.WhoAmI

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  setup do
    %{user: User.create!(factory(:user))}
  end

  describe "whoami" do
    test "returns the authenticated user", %{user: user} do
      assert %{"ok" => true, "data" => data} = invoke(WhoAmI, %{}, user)
      assert data["login"] == user.login
      assert data["id"] == user.id
    end
  end

  describe "repositories" do
    test "get_repository returns an owned repository", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => true, "data" => data} =
               invoke(GetRepository, %{owner: user.login, name: repo.name}, user)

      assert data["name"] == repo.name
      assert data["owner"] == user.login
    end

    test "get_repository reports a private repository of another user as not_found", %{user: user} do
      other = User.create!(factory(:user))
      repo = create_repo(other, %{public: false})

      assert %{"ok" => false, "error" => "not_found"} =
               invoke(GetRepository, %{owner: other.login, name: repo.name}, user)
    end

    test "search_repositories finds a repository by name", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => true, "data" => %{"repositories" => repos}} =
               invoke(SearchRepositories, %{query: repo.name, limit: 10}, user)

      assert Enum.any?(repos, &(&1["name"] == repo.name))
    end

    test "search returns repositories and users", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => true, "data" => %{"repositories" => repos, "users" => _users}} =
               invoke(Search, %{query: repo.name, limit: 10}, user)

      assert Enum.any?(repos, &(&1["name"] == repo.name))
    end
  end

  describe "issues" do
    test "list_issues, get_issue and list_issue_comments", %{user: user} do
      repo = create_repo(user)
      params = factory(:issue)
      issue = Issue.create!(repo, user, params)

      assert %{"ok" => true, "data" => %{"issues" => [listed]}} =
               invoke(ListIssues, %{owner: user.login, name: repo.name}, user)

      assert listed["number"] == issue.number
      assert listed["title"] == issue.title
      assert listed["comments_count"] == 0

      assert %{"ok" => true, "data" => got} =
               invoke(GetIssue, %{owner: user.login, name: repo.name, number: issue.number}, user)

      assert got["number"] == issue.number
      assert got["body"] == params.comment.body

      assert {:ok, _comment} = Issue.add_comment(issue, user, "A reply.")

      assert %{"ok" => true, "data" => %{"comments" => [comment]}} =
               invoke(
                 ListIssueComments,
                 %{owner: user.login, name: repo.name, number: issue.number},
                 user
               )

      assert comment["body"] == "A reply."
    end
  end

  describe "releases" do
    test "list_releases returns repository releases", %{user: user} do
      repo = create_repo(user)

      Release.create!(repo, user, %{
        title: "First release",
        description: "Initial release.",
        tag_version: "v1.0.0",
        revision: String.duplicate("a", 40)
      })

      assert %{"ok" => true, "data" => %{"releases" => [release]}} =
               invoke(ListReleases, %{owner: user.login, name: repo.name}, user)

      assert release["tag_version"] == "v1.0.0"
      assert release["title"] == "First release"
    end
  end

  describe "code" do
    test "list_branches, list_tags, get_tree, read_file and get_commit", %{user: user} do
      {repo, commit_oid} = create_repo_with_commit(user)
      params = %{owner: user.login, name: repo.name}

      assert %{"ok" => true, "data" => %{"branches" => branches}} =
               invoke(ListBranches, params, user)

      assert Enum.any?(branches, &(&1["name"] == repo.default_branch and &1["default"] == true))

      assert %{"ok" => true, "data" => %{"tags" => tags}} = invoke(ListTags, params, user)
      assert tags == []

      assert %{"ok" => true, "data" => %{"entries" => entries}} = invoke(GetTree, params, user)
      assert Enum.any?(entries, &(&1["name"] == "README.md" and &1["type"] == "blob"))

      assert %{"ok" => true, "data" => file} =
               invoke(ReadFile, Map.merge(params, %{path: "README.md"}), user)

      assert file["content"] == "hello world\n"
      assert file["encoding"] == "utf-8"
      assert file["truncated"] == false

      assert %{"ok" => true, "data" => commit} =
               invoke(GetCommit, Map.merge(params, %{oid: commit_oid}), user)

      assert commit["oid"] == commit_oid
      assert commit["message"] =~ "Initial commit"
      assert commit["parents"] == []
    end

    test "get_tree reports a missing revision as an error", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => false} =
               invoke(GetTree, %{owner: user.login, name: repo.name, revision: "nope"}, user)
    end
  end

  #
  # Helpers
  #

  defp invoke(module, params, user) do
    frame = Frame.new(%{current_user: user})
    {:reply, response, _frame} = module.execute(params, frame)
    [%{"text" => text} | _] = response.content
    Jason.decode!(text)
  end

  defp create_repo(user, overrides \\ %{}) do
    repo = Repo.create!(user, Map.merge(factory(:repo), overrides))

    on_exit(fn -> File.rm_rf(RepoStorage.workdir(repo)) end)

    repo
  end

  defp create_repo_with_commit(user) do
    repo = create_repo(user)

    {:ok, agent} = GitRepo.get_agent(repo)

    {:ok, oid} =
      GitAgent.transaction(agent, fn agent ->
        signature = %{
          name: user.name,
          email: "#{user.login}@example.com",
          timestamp: DateTime.now!("Etc/UTC")
        }

        with {:ok, odb} <- GitAgent.odb(agent),
             {:ok, blob_oid} <- GitAgent.odb_write(agent, odb, "hello world\n", :blob),
             {:ok, index} <- GitAgent.index(agent),
             :ok <-
               GitAgent.index_add(
                 agent,
                 index,
                 blob_oid,
                 "README.md",
                 byte_size("hello world\n"),
                 0o100644
               ),
             {:ok, tree_oid} <- GitAgent.index_write_tree(agent, index),
             {:ok, commit_oid} <-
               GitAgent.commit_create(agent, signature, signature, "Initial commit", tree_oid, [],
                 update_ref: "refs/heads/main"
               ) do
          {:ok, commit_oid}
        end
      end)

    {repo, Base.encode16(oid, case: :lower)}
  end
end
