defmodule GitGud.MCP.Tools.CheckpointProvenance do
  @moduledoc """
  MCP tool `checkpoint_provenance` — map a file (or a directory) back to the AI
  coding-agent checkpoints that touched it.

  This is the `blame`-style question an agent asks *before* changing a file: which
  sessions have already worked on it? The answer is `GitGud.Checkpoints.provenance/3`,
  which reads the `files_touched` of the indexed checkpoint summaries — no Git read
  beyond the `GitGud.MetaDB` index. See `guides/Sessions and Checkpoints.md`.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Checkpoints
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "checkpoint_provenance"

  @impl true
  def description do
    "List the AI coding-agent checkpoints that touched a file or directory, newest first (blame-style provenance)."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")

    field(:path, {:required, :string},
      description: "File path, or a directory (which matches every file below it)."
    )

    field(:limit, :integer, description: "Maximum checkpoints to return (1-100).", default: 25)
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    path = params[:path] |> to_string() |> String.trim()
    limit = Helpers.clamp_limit(params[:limit])

    result =
      with :ok <- validate_path(path),
           {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, matches} <- Checkpoints.provenance(repo, path) do
        {:ok,
         %{
           "total_count" => length(matches),
           "matches" => matches |> Enum.take(limit) |> Enum.map(&Helpers.checkpoint_match/1)
         }}
      end

    Helpers.reply(frame, result)
  end

  #
  # Helpers
  #

  defp validate_path(""), do: {:error, "empty_path"}
  defp validate_path(_path), do: :ok
end
