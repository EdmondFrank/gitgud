defmodule GitGud.MCP.Tools.SearchRepositories do
  @moduledoc """
  MCP tool `search_repositories` — search repositories by name (trigram similarity).
  Only repositories the caller may read are returned.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Tools.Helpers
  alias GitGud.RepoQuery

  def name, do: "search_repositories"

  @impl true
  def description do
    "Search repositories by name (trigram similarity). Only repositories the caller may read are returned."
  end

  schema do
    field(:query, :string,
      description: "Search text matched against repository names.",
      default: ""
    )

    field(:limit, :integer,
      description: "Maximum number of repositories to return (1-100).",
      default: 25
    )
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    query = params[:query] || ""
    limit = Helpers.clamp_limit(params[:limit])

    repos = RepoQuery.search(query, viewer: user, limit: limit)

    Helpers.reply(frame, {:ok, %{"repositories" => Enum.map(repos, &Helpers.repo/1)}})
  end
end
