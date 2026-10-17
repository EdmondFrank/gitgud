defmodule GitGud.MCP.Tools.ListBranches do
  @moduledoc """
  MCP tool `list_branches` — list a repository's branches with their commit oids.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  def name, do: "list_branches"

  @impl true
  def description do
    "List a repository's branches with their commit oids."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, agent} <- GitRepo.get_agent(repo),
           {:ok, refs} <- GitAgent.transaction(agent, &GitAgent.branches/1) do
        branches =
          Enum.map(refs, fn ref ->
            Map.put(Helpers.ref(ref), "default", ref.name == repo.default_branch)
          end)

        {:ok, %{"branches" => branches}}
      end

    Helpers.reply(frame, result)
  end
end
