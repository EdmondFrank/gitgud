defmodule GitGud.MCP.Tools.ListTags do
  @moduledoc """
  MCP tool `list_tags` — list a repository's tags with their oids.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  def name, do: "list_tags"

  @impl true
  def description do
    "List a repository's tags with their oids."
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
           {:ok, tags} <- GitAgent.transaction(agent, &GitAgent.tags/1) do
        {:ok, %{"tags" => Enum.map(tags, &Helpers.ref/1)}}
      end

    Helpers.reply(frame, result)
  end
end
