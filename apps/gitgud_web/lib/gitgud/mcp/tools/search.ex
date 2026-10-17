defmodule GitGud.MCP.Tools.Search do
  @moduledoc """
  MCP tool `search` — search repositories and users across the instance.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Tools.Helpers
  alias GitGud.RepoQuery
  alias GitGud.UserQuery

  def name, do: "search"

  @impl true
  def description do
    "Search repositories and users across the instance."
  end

  schema do
    field(:query, :string,
      description: "Search text matched against repository names and user logins.",
      default: ""
    )

    field(:limit, :integer, description: "Maximum results per category (1-100).", default: 25)
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    query = params[:query] || ""
    limit = Helpers.clamp_limit(params[:limit])

    repos = RepoQuery.search(query, viewer: user, limit: limit)
    users = UserQuery.search(query, limit: limit)

    Helpers.reply(
      frame,
      {:ok,
       %{
         "repositories" => Enum.map(repos, &Helpers.repo/1),
         "users" => Enum.map(users, &Helpers.user/1)
       }}
    )
  end
end
