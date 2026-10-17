defmodule GitGud.MCP.Tools.UpdateComment do
  @moduledoc """
  MCP tool `update_comment` — edit an existing comment's body.

  Mirrors the `update_comment` GraphQL resolver (`:edit` policy; the author or a
  repository admin). The comment must belong to the given repository.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Comment
  alias GitGud.CommentQuery
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "update_comment"

  @impl true
  def description do
    "Edit the body of an existing comment (author or repository admin only)."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:comment_id, {:required, :integer}, description: "Comment id.")
    field(:body, {:required, :string}, description: "New comment body (Markdown).")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, comment} <- fetch_comment(user, repo, params[:comment_id]),
           {:ok, comment} <- Authorization.enforce(user, comment, :edit) do
        case Comment.update(comment, user, body: params[:body]) do
          {:ok, updated} ->
            # `Comment.update/3` leaves the author unloaded; re-load it so the
            # response matches the read tools (never substitute the editor, who
            # may be a different user — e.g. an admin).
            comment = CommentQuery.by_id(updated.id, preload: [:author]) || updated
            {:ok, Helpers.comment(comment)}

          {:error, changeset} ->
            {:error, {:validation, Helpers.changeset_errors(changeset)}}
        end
      end

    Helpers.reply(frame, result)
  end

  #
  # Helpers
  #

  defp fetch_comment(user, repo, id) do
    case CommentQuery.by_id(id, viewer: user) do
      %Comment{} = comment ->
        if comment.repo_id == repo.id,
          do: {:ok, comment},
          else: {:error, :not_found}

      _other ->
        {:error, :not_found}
    end
  end
end
