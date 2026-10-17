defmodule GitGud.MCP.WriteToolsTest do
  @moduledoc """
  Unit tests for the `GitGud.MCP.Tools.*` write tools (see `guides/MCP.md` §11, Phase 4).

  Like the read-tool tests, tools are pure functions of `(params, frame)`; the
  authenticated user is supplied through `frame.assigns[:current_user]`.
  """

  use GitGud.Web.ConnCase, async: false
  use GitGud.Web.DataFactory

  alias Anubis.Server.Frame

  alias GitGud.Email
  alias GitGud.Issue
  alias GitGud.IssueQuery
  alias GitGud.Repo
  alias GitGud.RepoStorage
  alias GitGud.User

  alias GitGud.MCP.Tools.CloseIssue
  alias GitGud.MCP.Tools.CommentOnIssue
  alias GitGud.MCP.Tools.CreateCommitLineReviewComment
  alias GitGud.MCP.Tools.CreateIssue
  alias GitGud.MCP.Tools.DeleteComment
  alias GitGud.MCP.Tools.ReopenIssue
  alias GitGud.MCP.Tools.UpdateComment
  alias GitGud.MCP.Tools.UpdateIssueLabels
  alias GitGud.MCP.Tools.UpdateIssueTitle

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  setup do
    %{user: verified_user()}
  end

  describe "create_issue" do
    test "opens an issue with a body and labels", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => true, "data" => data} =
               invoke(
                 CreateIssue,
                 %{
                   owner: user.login,
                   name: repo.name,
                   title: "Bug",
                   body: "It crashes",
                   labels: "bug"
                 },
                 user
               )

      assert data["title"] == "Bug"
      assert data["number"] == 1
      assert data["body"] == "It crashes"
      assert data["labels"] == ["bug"]
    end

    test "reports validation errors", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => false, "error" => "validation_error"} =
               invoke(
                 CreateIssue,
                 %{owner: user.login, name: repo.name, title: "", body: ""},
                 user
               )
    end

    test "reports an unknown label", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => false, "error" => "label_not_found: nope"} =
               invoke(
                 CreateIssue,
                 %{
                   owner: user.login,
                   name: repo.name,
                   title: "Bug",
                   body: "It crashes",
                   labels: "nope"
                 },
                 user
               )
    end

    test "is forbidden for an unverified user", %{user: _user} do
      user = User.create!(factory(:user))
      repo = create_repo(user)

      assert %{"ok" => false, "error" => "forbidden"} =
               invoke(
                 CreateIssue,
                 %{owner: user.login, name: repo.name, title: "Bug", body: "x"},
                 user
               )
    end

    test "is not found for a private repository of another user", %{user: user} do
      other = verified_user()
      repo = create_repo(other, %{public: false})

      assert %{"ok" => false, "error" => "not_found"} =
               invoke(
                 CreateIssue,
                 %{owner: other.login, name: repo.name, title: "Bug", body: "x"},
                 user
               )
    end
  end

  describe "issue mutations" do
    test "comment_on_issue, update_issue_title and update_issue_labels", %{user: user} do
      repo = create_repo(user)
      issue = Issue.create!(repo, user, factory(:issue))

      assert %{"ok" => true, "data" => comment} =
               invoke(
                 CommentOnIssue,
                 %{owner: user.login, name: repo.name, number: issue.number, body: "A reply."},
                 user
               )

      assert comment["body"] == "A reply."

      assert %{"ok" => true, "data" => renamed} =
               invoke(
                 UpdateIssueTitle,
                 %{owner: user.login, name: repo.name, number: issue.number, title: "Renamed"},
                 user
               )

      assert renamed["title"] == "Renamed"

      assert %{"ok" => true, "data" => labelled} =
               invoke(
                 UpdateIssueLabels,
                 %{
                   owner: user.login,
                   name: repo.name,
                   number: issue.number,
                   push: "bug,question"
                 },
                 user
               )

      assert Enum.sort(labelled["labels"]) == ["bug", "question"]

      assert %{"ok" => true, "data" => unlabelled} =
               invoke(
                 UpdateIssueLabels,
                 %{owner: user.login, name: repo.name, number: issue.number, pull: "bug"},
                 user
               )

      assert unlabelled["labels"] == ["question"]
    end

    test "close_issue and reopen_issue", %{user: user} do
      repo = create_repo(user)
      issue = Issue.create!(repo, user, factory(:issue))

      assert %{"ok" => true, "data" => %{"status" => "close"}} =
               invoke(
                 CloseIssue,
                 %{owner: user.login, name: repo.name, number: issue.number},
                 user
               )

      assert %{"ok" => true, "data" => %{"status" => "open"}} =
               invoke(
                 ReopenIssue,
                 %{owner: user.login, name: repo.name, number: issue.number},
                 user
               )
    end

    test "a verified non-author cannot close an issue", %{user: user} do
      repo = create_repo(user)
      issue = Issue.create!(repo, user, factory(:issue))
      other = verified_user()

      assert %{"ok" => false, "error" => "forbidden"} =
               invoke(
                 CloseIssue,
                 %{owner: user.login, name: repo.name, number: issue.number},
                 other
               )
    end

    test "reports a missing issue as not_found", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => false, "error" => "not_found"} =
               invoke(
                 CommentOnIssue,
                 %{owner: user.login, name: repo.name, number: 999, body: "x"},
                 user
               )
    end
  end

  describe "comment mutations" do
    test "the author can update and delete a comment", %{user: user} do
      repo = create_repo(user)
      issue = Issue.create!(repo, user, factory(:issue))
      {:ok, comment} = Issue.add_comment(issue, user, "Original.")

      assert %{"ok" => true, "data" => updated} =
               invoke(
                 UpdateComment,
                 %{owner: user.login, name: repo.name, comment_id: comment.id, body: "Edited."},
                 user
               )

      assert updated["id"] == comment.id
      assert updated["body"] == "Edited."

      assert %{"ok" => true, "data" => %{"deleted" => true}} =
               invoke(
                 DeleteComment,
                 %{owner: user.login, name: repo.name, comment_id: comment.id},
                 user
               )

      assert IssueQuery.by_id(issue.id, preload: :replies).replies == []
    end

    test "a verified non-author cannot edit a comment", %{user: user} do
      repo = create_repo(user)
      issue = Issue.create!(repo, user, factory(:issue))
      {:ok, comment} = Issue.add_comment(issue, user, "Original.")
      other = verified_user()

      assert %{"ok" => false, "error" => "forbidden"} =
               invoke(
                 UpdateComment,
                 %{owner: user.login, name: repo.name, comment_id: comment.id, body: "Edited."},
                 other
               )
    end
  end

  describe "create_commit_line_review_comment" do
    test "adds a review comment on a diff line", %{user: user} do
      {repo, commit_oid, blob_oid} = create_repo_with_commit(user)

      assert %{"ok" => true, "data" => data} =
               invoke(
                 CreateCommitLineReviewComment,
                 %{
                   owner: user.login,
                   name: repo.name,
                   commit_oid: commit_oid,
                   blob_oid: blob_oid,
                   hunk: 0,
                   line: 0,
                   body: "Nit: rename this."
                 },
                 user
               )

      assert is_integer(data["review_id"])
      assert data["comment"]["body"] == "Nit: rename this."
    end

    test "rejects an invalid oid", %{user: user} do
      repo = create_repo(user)

      assert %{"ok" => false, "error" => "invalid_oid"} =
               invoke(
                 CreateCommitLineReviewComment,
                 %{
                   owner: user.login,
                   name: repo.name,
                   commit_oid: "not-an-oid",
                   blob_oid: "not-an-oid",
                   hunk: 0,
                   line: 0,
                   body: "x"
                 },
                 user
               )
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

  # A user with a verified primary email (mirrors `GitGud.UserQueryTest`).
  defp verified_user do
    user = User.create!(factory(:user))

    struct(user,
      emails: Enum.map(user.emails, &Email.verify!/1),
      primary_email_id: hd(user.emails).id
    )
  end

  defp create_repo(user, overrides \\ %{}) do
    repo = Repo.create!(user, Map.merge(factory(:repo), overrides))

    on_exit(fn -> File.rm_rf(RepoStorage.workdir(repo)) end)

    repo
  end

  defp create_repo_with_commit(user) do
    repo = create_repo(user)

    {:ok, agent} = GitRepo.get_agent(repo)

    {:ok, {commit_oid, blob_oid}} =
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
          {:ok, {commit_oid, blob_oid}}
        end
      end)

    {repo, Base.encode16(commit_oid, case: :lower), Base.encode16(blob_oid, case: :lower)}
  end
end
