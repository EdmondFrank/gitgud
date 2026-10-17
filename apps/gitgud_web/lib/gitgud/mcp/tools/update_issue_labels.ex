defmodule GitGud.MCP.Tools.UpdateIssueLabels do
  @moduledoc """
  MCP tool `update_issue_labels` — add and/or remove labels on an issue.

  Mirrors the `update_issue_labels` GraphQL resolver (`:edit_labels` policy), but
  accepts label **names** (comma-separated) and resolves them to the repository's
  labels, which is friendlier for an agent than opaque label ids.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Issue
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "update_issue_labels"

  @impl true
  def description do
    "Add and/or remove labels on an existing issue (labels are given by name)."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:number, {:required, :integer}, description: "Issue number.")
    field(:push, :string, description: "Comma-separated label names to add.")
    field(:pull, :string, description: "Comma-separated label names to remove.")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, repo, issue} <-
             Helpers.fetch_issue(user, params,
               preload: [:author, :comment, :labels],
               repo: [preload: [:issue_labels]]
             ),
           {:ok, issue} <- Authorization.enforce(user, issue, :edit_labels),
           {:ok, push} <- Helpers.resolve_labels(repo, Helpers.labels(params[:push])),
           {:ok, pull} <- Helpers.resolve_labels(repo, Helpers.labels(params[:pull])) do
        labels_push = Enum.map(push, & &1.id)
        labels_pull = Enum.map(pull, & &1.id)

        if labels_push == [] and labels_pull == [] do
          {:ok, Helpers.issue(issue)}
        else
          case Issue.update_labels(issue, {labels_push, labels_pull}, user_id: user.id) do
            {:ok, issue} -> {:ok, Helpers.issue(issue)}
            {:error, reason} -> {:error, {:validation, Helpers.changeset_errors(reason)}}
          end
        end
      end

    Helpers.reply(frame, result)
  end
end
