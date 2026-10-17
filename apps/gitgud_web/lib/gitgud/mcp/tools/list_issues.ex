defmodule GitGud.MCP.Tools.ListIssues do
  @moduledoc """
  MCP tool `list_issues` — list a repository's issues, newest first, with comment counts.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.IssueQuery
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "list_issues"

  @impl true
  def description do
    "List a repository's issues, newest first, with comment counts."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:status, :string, description: "Filter by status: open, close or all (default).")
    field(:labels, :string, description: "Comma-separated label names to filter by.")

    field(:limit, :integer,
      description: "Maximum number of issues to return (1-100).",
      default: 25
    )

    field(:offset, :integer, description: "Number of issues to skip.", default: 0)
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    limit = Helpers.clamp_limit(params[:limit])
    offset = Helpers.clamp_offset(params[:offset])
    labels = Helpers.labels(params[:labels])

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]) do
        opts = [
          limit: limit,
          offset: offset,
          labels: labels,
          preload: [:author, :labels, :comment]
        ]

        opts =
          case Helpers.issue_status(params[:status]) do
            nil -> opts
            status -> Keyword.put(opts, :status, status)
          end

        issues = IssueQuery.repo_issues_with_reply_count(repo, opts)

        {:ok,
         %{
           "issues" =>
             Enum.map(issues, fn {issue, count} ->
               Map.put(Helpers.issue(issue), "comments_count", count)
             end)
         }}
      end

    Helpers.reply(frame, result)
  end
end
