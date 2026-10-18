defmodule GitGud.Web.CheckpointLiveTest do
  @moduledoc """
  Coverage for the repository *Sessions* tab (`GitGud.Web.CheckpointLive`), which
  renders the AI coding-agent checkpoints the Entire CLI pushes as
  `refs/entire/checkpoints/<shard>/<id>`.

  The fixture lives in `GitGud.Web.CheckpointFactory`, shared with the Phase 3
  GraphQL/MCP tests.
  """

  use GitGud.Web.ConnCase, async: false
  use GitGud.Web.DataFactory

  import Phoenix.LiveViewTest

  alias GitGud.Checkpoints
  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.User
  alias GitGud.Web.CheckpointFactory

  setup [:create_user, :create_repo]

  describe "without checkpoints" do
    test "renders the empty state", %{conn: conn, user: user, repo: repo} do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions")

      assert html =~ "Sessions"
      assert html =~ "No AI coding-agent sessions have been recorded"
      assert html =~ "entire enable"
    end

    test "warns that a public repository exposes checkpoint contents", %{
      conn: conn,
      user: user,
      repo: repo
    } do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions")

      assert html =~ "This repository is public"
      assert html =~ "can be read by anyone who can clone it"
    end
  end

  describe "with a checkpoint" do
    setup :create_checkpoint

    test "lists the checkpoint", %{conn: conn, user: user, repo: repo, main_sha: main_sha} do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions")

      assert html =~ String.slice(checkpoint_id(), 0, 7)
      assert html =~ String.slice(main_sha, 0, 7)
      assert html =~ "158 in / 54 out"
      assert html =~ "main"
    end

    test "renders the checkpoint detail", %{conn: conn, user: user, repo: repo} do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions/#{checkpoint_id()}")

      assert html =~ "Add a greeting to the README"
      assert html =~ "Done — added it."
      assert html =~ "README.md"
      assert html =~ "SECOND.md"
      assert html =~ "task-1"
      assert html =~ "Add a greeting"
      assert html =~ "158 in / 54 out"
    end

    test "renders the diff against the linked commit", %{conn: conn, user: user, repo: repo} do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions/#{checkpoint_id()}")

      assert html =~ "SECOND.md"
      assert html =~ "View full commit"
    end

    test "paginates the transcript", %{conn: conn, user: user, repo: repo} do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions/#{checkpoint_id()}")

      assert html =~ "Showing 100 of 150 lines"
      assert html =~ "line 3"
      assert html =~ "page=2"
      refute html =~ "line 101"

      {:ok, _view, html} =
        live(conn, ~p"/#{user.login}/#{repo.name}/sessions/#{checkpoint_id()}?page=2")

      assert html =~ "line 101"
      assert html =~ "Showing 50 of 150 lines"
    end

    test "links the checkpoint from the commit history", %{conn: conn, user: user, repo: repo} do
      {:ok, _view, html} =
        live(conn, ~p"/#{user.login}/#{repo.name}/commits/#{repo.default_branch}/")

      assert html =~ "/sessions/#{checkpoint_id()}"
    end

    test "redirects away from an unknown checkpoint", %{conn: conn, user: user, repo: repo} do
      result = live(conn, ~p"/#{user.login}/#{repo.name}/sessions/01K9TQ8ZP7X3F5M2WVJ4CNRBZZ")

      assert {:error, {:live_redirect, %{to: to}}} = result
      assert to == ~p"/#{user.login}/#{repo.name}/sessions"
    end

    test "searches the recorded sessions", %{conn: conn, user: user, repo: repo} do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions?q=greeting")

      assert html =~ String.slice(checkpoint_id(), 0, 7)
      assert html =~ "session 0 prompt"
      assert html =~ ~s(value="greeting")
      assert html =~ "Clear"
    end

    test "matches a checkpoint on both its files and its prompt", %{
      conn: conn,
      user: user,
      repo: repo
    } do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions?q=readme")

      assert html =~ "files_touched"
      assert html =~ "session 0 prompt"
    end

    test "shows an empty state when no session matches", %{conn: conn, user: user, repo: repo} do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions?q=nonexistent")

      assert html =~ "No recorded sessions match"
      assert html =~ "nonexistent"
      refute html =~ String.slice(checkpoint_id(), 0, 7)
    end

    test "shows a repository admin the checkpoint storage report", %{
      conn: conn,
      user: user,
      repo: repo
    } do
      conn = init_test_session(conn, user_id: user.id)
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions")

      assert html =~ "Checkpoint storage"
      assert html =~ "1 checkpoint,"
    end

    test "hides the checkpoint storage report from a non-admin viewer", %{
      conn: conn,
      user: user,
      repo: repo
    } do
      {:ok, _view, html} = live(conn, ~p"/#{user.login}/#{repo.name}/sessions")

      refute html =~ "Checkpoint storage"
    end
  end

  #
  # Helpers
  #

  defp checkpoint_id, do: CheckpointFactory.checkpoint_id()

  defp create_user(context) do
    user = User.create!(factory(:user))

    on_exit(fn ->
      File.rmdir(
        Path.join(
          Keyword.fetch!(Application.get_env(:gitgud, RepoStorage), :git_root),
          user.login
        )
      )
    end)

    Map.put(context, :user, user)
  end

  defp create_repo(context) do
    repo = Repo.create!(context.user, factory(:repo))

    on_exit(fn ->
      File.rm_rf(RepoStorage.workdir(repo))
      Checkpoints.invalidate(repo)
    end)

    Map.put(context, :repo, repo)
  end

  defp create_checkpoint(%{repo: repo} = context) do
    %{main_sha: main_sha} = CheckpointFactory.write!(repo)

    Map.put(context, :main_sha, main_sha)
  end
end
