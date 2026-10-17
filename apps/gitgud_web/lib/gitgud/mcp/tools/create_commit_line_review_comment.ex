defmodule GitGud.MCP.Tools.CreateCommitLineReviewComment do
  @moduledoc """
  MCP tool `create_commit_line_review_comment` — comment on a line of a commit diff.

  Mirrors the `create_commit_line_review_comment` GraphQL resolver: the repository
  must be readable and the caller must have a verified primary email. The
  `commit_oid` and `blob_oid` are 40-character hex object ids; `hunk` and `line`
  locate the diff line (both zero-based, as in the web UI).
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.CommitLineReview
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "create_commit_line_review_comment"

  @impl true
  def description do
    "Add a review comment to a specific line of a commit's diff."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:commit_oid, {:required, :string}, description: "Commit object id (40-char hex).")

    field(:blob_oid, {:required, :string},
      description: "Blob object id of the reviewed file (40-char hex)."
    )

    field(:hunk, {:required, :integer}, description: "Zero-based index of the diff hunk.")

    field(:line, {:required, :integer},
      description: "Zero-based index of the line within the hunk."
    )

    field(:body, {:required, :string}, description: "Comment body (Markdown).")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           :ok <- Helpers.ensure_verified(user),
           {:ok, commit_oid} <- Helpers.parse_oid(params[:commit_oid]),
           {:ok, blob_oid} <- Helpers.parse_oid(params[:blob_oid]) do
        case CommitLineReview.add_comment(
               repo,
               commit_oid,
               blob_oid,
               params[:hunk],
               params[:line],
               user,
               params[:body],
               with_review: true
             ) do
          {:ok, comment, review} ->
            {:ok, %{"review_id" => review.id, "comment" => Helpers.comment(comment)}}

          {:ok, comment} ->
            {:ok, %{"comment" => Helpers.comment(comment)}}

          {:error, changeset} ->
            {:error, {:validation, Helpers.changeset_errors(changeset)}}
        end
      end

    Helpers.reply(frame, result)
  end
end
