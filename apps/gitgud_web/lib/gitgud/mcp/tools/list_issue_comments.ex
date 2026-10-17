defmodule GitGud.MCP.Tools.ListIssueComments do
  @moduledoc """
  MCP tool `list_issue_comments` — list the comments (replies) of an issue.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.IssueQuery
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "list_issue_comments"

  @impl true
  def description do
    "List the comments (replies) of an issue."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:number, {:required, :integer}, description: "Issue number.")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]) do
        case IssueQuery.repo_issue(repo, params[:number], preload: [replies: :author]) do
          nil -> {:error, :not_found}
          issue -> {:ok, %{"comments" => Enum.map(issue.replies, &Helpers.comment/1)}}
        end
      end

    Helpers.reply(frame, result)
  end
end
