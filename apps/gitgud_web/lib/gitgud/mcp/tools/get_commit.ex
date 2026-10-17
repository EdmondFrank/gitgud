defmodule GitGud.MCP.Tools.GetCommit do
  @moduledoc """
  MCP tool `get_commit` — fetch a commit's metadata and diffstat against its first parent.
  """

  use Anubis.Server.Component, type: :tool

  alias GitGud.MCP.Authorization
  alias GitGud.MCP.Tools.Helpers

  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  def name, do: "get_commit"

  @impl true
  def description do
    "Fetch a commit's metadata (author, committer, message, parents) and diffstat against its first parent."
  end

  schema do
    field(:owner, {:required, :string}, description: "Repository owner login.")
    field(:name, {:required, :string}, description: "Repository name.")
    field(:oid, {:required, :string}, description: "Commit object id.")
  end

  @impl true
  def execute(params, frame) do
    user = Helpers.current_user(frame)

    result =
      with {:ok, oid} <- Helpers.parse_oid(params[:oid]),
           {:ok, repo} <- Authorization.fetch_repo(user, params[:owner], params[:name]),
           {:ok, agent} <- GitRepo.get_agent(repo) do
        GitAgent.transaction(agent, fn agent ->
          with {:ok, commit} <- GitAgent.object(agent, oid) do
            commit_info(agent, commit)
          end
        end)
      end

    Helpers.reply(frame, result)
  end

  #
  # Helpers
  #

  defp commit_info(agent, commit) do
    with {:ok, timestamp} <- GitAgent.commit_timestamp(agent, commit),
         {:ok, message} <- GitAgent.commit_message(agent, commit),
         {:ok, author} <- GitAgent.commit_author(agent, commit),
         {:ok, committer} <- GitAgent.commit_committer(agent, commit),
         {:ok, parents} <- GitAgent.commit_parents(agent, commit) do
      parent_oids = Enum.map(parents, &Helpers.oid(&1.oid))

      {:ok,
       %{
         "oid" => Helpers.oid(commit.oid),
         "message" => message,
         "author" => Helpers.git_author(author),
         "committer" => Helpers.git_author(committer),
         "timestamp" => Helpers.datetime(timestamp),
         "parents" => parent_oids,
         "diffstat" => diffstat(agent, Enum.map(parents, & &1.oid), commit)
       }}
    end
  end

  defp diffstat(agent, [parent_oid | _], commit) do
    with {:ok, parent} <- GitAgent.object(agent, parent_oid),
         {:ok, diff} <- GitAgent.diff(agent, parent, commit),
         {:ok, stats} <- GitAgent.diff_stats(agent, diff) do
      stats
    else
      _other -> nil
    end
  end

  defp diffstat(_agent, [], _commit), do: nil
end
