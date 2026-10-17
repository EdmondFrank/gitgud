defmodule GitGud.MCP.Tools.GetIssue do
  @moduledoc """
  MCP tool `get_issue` — fetch a single issue by number, including its body.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.IssueQuery
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "get_issue"

  @impl true
  def description do
    "Fetch a single issue by number, including its body."
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
        case IssueQuery.repo_issue(repo, params[:number], preload: [:author, :labels, :comment]) do
          nil -> {:error, :not_found}
          issue -> {:ok, Helpers.issue(issue)}
        end
      end

    Helpers.reply(frame, result)
  end
end
