defmodule GitGud.GraphQL.RepoMiddleware do
  @moduledoc false

  @behaviour Absinthe.Middleware

  alias GitRekt.GitRepo

  alias GitGud.Repo
  alias GitGud.RepoQuery
  alias GitGud.GraphQL.Schema

  import Absinthe.Resolution, only: [put_result: 2]

  #
  # Callbacks
  #

  @impl true
  def call(%Absinthe.Resolution{source: %{repo_id: repo_id}, context: ctx} = resolution, []) do
    cond do
      Map.has_key?(ctx, :repo) ->
        resolution
      repo = RepoQuery.by_id(repo_id, viewer: ctx[:current_user]) ->
        put_repo_ctx(resolution, repo)
      true ->
        put_result(resolution, {:error, "this given repository id '#{Schema.to_relay_id(repo_id, Repo)}' is not valid"})
    end
  end

  def call(%Absinthe.Resolution{} = resolution, %Repo{} = repo) do
    resolution
    |> put_repo_ctx(repo)
    |> put_result({:ok, repo})
  end

  #
  # Helpers
  #

  defp put_repo_ctx(resolution, repo) do
    {:ok, agent} = GitRepo.get_agent(repo)
    resolution
    |> Map.update!(:context, &Map.put(&1, :repo, repo))
    |> Map.update!(:context, &Map.put(&1, :repo_agent, agent))
    |> Map.update!(:context, &Map.put(&1, :repo_perms, RepoQuery.permissions(&1.repo, &1[:current_user])))
  end
end
