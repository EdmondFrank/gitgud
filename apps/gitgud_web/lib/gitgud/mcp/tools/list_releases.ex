defmodule GitGud.MCP.Tools.ListReleases do
  @moduledoc """
  MCP tool `list_releases` — list a repository's releases.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers
  alias GitGud.ReleaseQuery

  def name, do: "list_releases"

  @impl true
  def description do
    "List a repository's releases."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")

    field(:limit, :integer,
      description: "Maximum number of releases to return (1-100).",
      default: 25
    )
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    limit = Helpers.clamp_limit(params[:limit])

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]) do
        releases = ReleaseQuery.repo_releases(repo, limit: limit, preload: [:author])
        {:ok, %{"releases" => Enum.map(releases, &Helpers.release/1)}}
      end

    Helpers.reply(frame, result)
  end
end
