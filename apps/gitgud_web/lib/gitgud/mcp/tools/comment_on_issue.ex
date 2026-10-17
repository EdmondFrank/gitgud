defmodule GitGud.MCP.Tools.CommentOnIssue do
  @moduledoc """
  MCP tool `comment_on_issue` — add a comment to an existing issue.

  Mirrors the `create_issue_comment` GraphQL resolver: the issue is loaded from
  the repository and the `:comment` policy is enforced before writing.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Issue
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "comment_on_issue"

  @impl true
  def description do
    "Add a comment to an existing issue."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:number, {:required, :integer}, description: "Issue number.")
    field(:body, {:required, :string}, description: "Comment body (Markdown).")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, _repo, issue} <- Helpers.fetch_issue(user, params),
           {:ok, issue} <- Authorization.enforce(user, issue, :comment) do
        case Issue.add_comment(issue, user, params[:body]) do
          {:ok, comment} -> {:ok, Helpers.comment(comment)}
          {:error, changeset} -> {:error, {:validation, Helpers.changeset_errors(changeset)}}
        end
      end

    Helpers.reply(frame, result)
  end
end
