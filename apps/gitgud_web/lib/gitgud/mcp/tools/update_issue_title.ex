defmodule GitGud.MCP.Tools.UpdateIssueTitle do
  @moduledoc """
  MCP tool `update_issue_title` — change an issue's title.

  Mirrors the `update_issue_title` GraphQL resolver (`:edit_title` policy).
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Issue
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "update_issue_title"

  @impl true
  def description do
    "Change the title of an existing issue."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:number, {:required, :integer}, description: "Issue number.")
    field(:title, {:required, :string}, description: "New issue title.")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, _repo, issue} <- Helpers.fetch_issue(user, params),
           {:ok, issue} <- Authorization.enforce(user, issue, :edit_title) do
        if issue.title == params[:title] do
          {:ok, Helpers.issue_ref(issue)}
        else
          case Issue.update_title(issue, params[:title], user_id: user.id) do
            {:ok, issue} -> {:ok, Helpers.issue_ref(issue)}
            {:error, changeset} -> {:error, {:validation, Helpers.changeset_errors(changeset)}}
          end
        end
      end

    Helpers.reply(frame, result)
  end
end
