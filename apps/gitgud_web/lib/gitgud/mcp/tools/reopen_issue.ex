defmodule GitGud.MCP.Tools.ReopenIssue do
  @moduledoc """
  MCP tool `reopen_issue` — reopen a closed issue.

  Mirrors the `reopen_issue` GraphQL resolver (`:reopen` policy). Reopening an
  already-open issue is a no-op.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Issue
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "reopen_issue"

  @impl true
  def description do
    "Reopen a closed issue."
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
      with {:ok, _repo, issue} <- Helpers.fetch_issue(user, params),
           {:ok, issue} <- Authorization.enforce(user, issue, :reopen) do
        case Issue.reopen(issue, user_id: user.id) do
          {:ok, issue} -> {:ok, Helpers.issue_ref(issue)}
          {:error, changeset} -> {:error, {:validation, Helpers.changeset_errors(changeset)}}
        end
      end

    Helpers.reply(frame, result)
  end
end
