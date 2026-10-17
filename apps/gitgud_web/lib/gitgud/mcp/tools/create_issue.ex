defmodule GitGud.MCP.Tools.CreateIssue do
  @moduledoc """
  MCP tool `create_issue` — open a new issue on a repository.

  Mirrors `GitGud.Web.IssueController.create/2`: the repository must be readable
  by the caller and the caller must have a verified primary email. The author is
  taken from the authenticated session; optional labels are resolved by name
  against the repository's labels.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Issue
  alias GitGud.IssueQuery
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "create_issue"

  @impl true
  def description do
    "Open a new issue on a repository. The authenticated user becomes the author."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:title, {:required, :string}, description: "Issue title.")
    field(:body, {:required, :string}, description: "Issue body (Markdown).")
    field(:labels, :string, description: "Comma-separated label names to apply.")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, repo} <-
             Authorization.fetch_repo(user, params[:owner], params[:name],
               preload: [:issue_labels]
             ),
           :ok <- Helpers.ensure_verified(user),
           {:ok, labels} <- Helpers.resolve_labels(repo, Helpers.labels(params[:labels])) do
        attrs = %{
          "title" => params[:title],
          "comment" => %{"body" => params[:body]},
          "labels" => labels
        }

        case Issue.create(repo, user, attrs) do
          {:ok, issued} ->
            # `Issue.create/3` returns the issue without its author preloaded;
            # re-load it so the response carries the author like the read tools.
            issue =
              IssueQuery.repo_issue(repo, issued.number, preload: [:author, :labels, :comment])

            {:ok, Helpers.issue(issue)}

          {:error, changeset} ->
            {:error, {:validation, Helpers.changeset_errors(changeset)}}
        end
      end

    Helpers.reply(frame, result)
  end
end
