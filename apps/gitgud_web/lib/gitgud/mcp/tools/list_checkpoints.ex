defmodule GitGud.MCP.Tools.ListCheckpoints do
  @moduledoc """
  MCP tool `list_checkpoints` — list a repository's AI coding-agent checkpoints.

  Checkpoints are recorded by the [Entire CLI](https://github.com/entireio/cli)
  and pushed to gitfrank as `refs/entire/checkpoints/<shard>/<id>`. See
  `guides/Sessions and Checkpoints.md`.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.Checkpoints
  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "list_checkpoints"

  @impl true
  def description do
    "List a repository's AI coding-agent checkpoints (recorded by the Entire CLI), newest first."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:limit, :integer, description: "Maximum checkpoints to return (1-100).", default: 25)

    field(:offset, :integer,
      description: "Number of checkpoints to skip, for pagination.",
      default: 0
    )
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    limit = Helpers.clamp_limit(params[:limit])
    offset = Helpers.clamp_offset(params[:offset])

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, checkpoints} <- Checkpoints.list(repo) do
        page =
          checkpoints
          |> Enum.drop(offset)
          |> Enum.take(limit)
          |> Enum.map(&Helpers.checkpoint/1)

        {:ok, %{"total_count" => length(checkpoints), "checkpoints" => page}}
      end

    Helpers.reply(frame, result)
  end
end
