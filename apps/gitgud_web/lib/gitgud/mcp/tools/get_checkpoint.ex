defmodule GitGud.MCP.Tools.GetCheckpoint do
  @moduledoc """
  MCP tool `get_checkpoint` — fetch a single AI coding-agent checkpoint.

  Returns the checkpoint's summary and its raw `metadata.json`, plus its subagent
  tasks. Pass `session` to also get that session's user prompt and agent
  transcript; the transcript is capped (`max_bytes`) so the response stays
  bounded. See `guides/Sessions and Checkpoints.md`.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Checkpoints
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "get_checkpoint"

  @impl true
  def description do
    "Fetch an AI coding-agent checkpoint by id: its metadata, tasks, and (optionally) one session's prompt and transcript."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:id, {:required, :string}, description: "Checkpoint id.")

    field(:session, :integer,
      description: "0-based session index whose prompt and transcript to include."
    )

    field(:max_bytes, :integer,
      description: "Cap on the transcript size in bytes (default 262144)."
    )
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    id = params[:id]
    max_bytes = Helpers.clamp_max_bytes(params[:max_bytes])

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, checkpoint} <- fetch_checkpoint(repo, id),
           {:ok, tasks} <- Checkpoints.tasks(repo, id),
           {:ok, session} <- read_session(repo, id, params[:session], max_bytes) do
        {:ok,
         checkpoint
         |> Helpers.checkpoint()
         |> Map.put("tasks", Enum.map(tasks, &task/1))
         |> put_session(session)}
      end

    Helpers.reply(frame, result)
  end

  #
  # Helpers
  #

  # An id may be a full ULID or an unambiguous prefix of one; `:ambiguous` is not a
  # plain "not found" and says so.
  defp fetch_checkpoint(repo, id) do
    case Checkpoints.get(repo, id) do
      {:ok, checkpoint} ->
        {:ok, checkpoint}

      {:error, :ambiguous} ->
        {:error, "ambiguous_checkpoint_id: #{id} matches more than one checkpoint"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_session(_repo, _id, nil, _max_bytes), do: {:ok, nil}

  defp read_session(repo, id, index, max_bytes) when is_integer(index) do
    case Checkpoints.session(repo, id, index, max_bytes: max_bytes) do
      {:ok, session} ->
        {:ok,
         %{
           "index" => session.index,
           "prompt" => session.prompt,
           "transcript" => session.transcript,
           "transcript_bytes" => session.transcript_bytes,
           "truncated" => session.truncated,
           "metadata" => session.metadata
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_session(checkpoint, nil), do: checkpoint
  defp put_session(checkpoint, session), do: Map.put(checkpoint, "session", session)

  defp task(%{id: id, data: data}), do: %{"id" => id, "task" => data}
end
