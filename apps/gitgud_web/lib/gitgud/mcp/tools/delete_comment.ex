defmodule GitGud.MCP.Tools.DeleteComment do
  @moduledoc """
  MCP tool `delete_comment` — delete an existing comment.

  Mirrors the `delete_comment` GraphQL resolver (`:delete` policy; the author or a
  repository admin). The comment must belong to the given repository.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Comment
  alias GitGud.CommentQuery
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "delete_comment"

  @impl true
  def description do
    "Delete an existing comment (author or repository admin only)."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:comment_id, {:required, :integer}, description: "Comment id.")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, comment} <- fetch_comment(user, repo, params[:comment_id]),
           {:ok, comment} <- Authorization.enforce(user, comment, :delete) do
        case Comment.delete(comment) do
          {:ok, comment} -> {:ok, %{"id" => comment.id, "deleted" => true}}
          {:error, changeset} -> {:error, {:validation, Helpers.changeset_errors(changeset)}}
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
