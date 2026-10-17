defmodule GitGud.MCP.Tools.GetRepository do
  @moduledoc """
  MCP tool `get_repository` — fetch a single repository's metadata.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  def name, do: "get_repository"

  @impl true
  def description do
    "Fetch a single repository's metadata."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]) do
        {:ok, Helpers.repo(repo)}
      end

    Helpers.reply(frame, result)
  end
end
