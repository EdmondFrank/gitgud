defmodule GitGud.MCP.Tools.GetTree do
  @moduledoc """
  MCP tool `get_tree` — list the entries of a repository tree at a revision/path.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  def name, do: "get_tree"

  @impl true
  def description do
    "List the entries of a repository tree at a given revision and path."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")

    field(:revision, :string,
      description: "Branch, tag or commit oid (default: the repository default branch)."
    )

    field(:path, :string,
      description: "Tree path relative to the repository root (default: root)."
    )
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)
    path = params[:path] || ""

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, agent} <- GitRepo.get_agent(repo) do
        revision = params[:revision] || repo.default_branch

        GitAgent.transaction(agent, fn agent ->
          with {:ok, {object, _ref}} <- GitAgent.revision(agent, revision),
               {:ok, commit} <- GitAgent.peel(agent, object, target: :commit),
               {:ok, entries} <- tree_entries(agent, commit, path) do
            {:ok,
             %{
               "revision" => revision,
               "commit" => Helpers.oid(commit.oid),
               "path" => path,
               "entries" => Enum.map(entries, &Helpers.tree_entry/1)
             }}
          end
        end)
      end

    Helpers.reply(frame, result)
  end

  #
  # Helpers
  #

  defp tree_entries(agent, commit, path) do
    case String.trim(path) do
      "" -> GitAgent.tree_entries(agent, commit)
      path -> GitAgent.tree_entries(agent, commit, path: path)
    end
  end
end
