defmodule GitGud.ReleaseQuery do
  @moduledoc """
  Conveniences for release related queries.
  """

  @behaviour GitGud.DBQueryable

  alias GitGud.DB
  alias GitGud.DBQueryable

  alias GitGud.Repo
  alias GitGud.Release

  import Ecto.Query

  @doc """
  Returns a repository for the given `id`.
  """
  @spec by_id(pos_integer, keyword) :: Repo.t | nil
  @spec by_id([pos_integer], keyword) :: [Repo.t]
  def by_id(id, opts \\ [])
  def by_id(ids, opts) when is_list(ids) do
    DB.all(DBQueryable.query({__MODULE__, :release_query}, [ids], opts))
  end

  def by_id(id, opts) do
    DB.one(DBQueryable.query({__MODULE__, :release_query}, id, opts))
  end

  @doc """
  Returns all releases for the given `repo`.
  """
  @spec repo_releases(Repo.t | pos_integer(), keyword()) :: [Release.t]
  def repo_releases(repo, opts \\ [])
  def repo_releases(%Repo{id: repo_id}, opts), do: repo_releases(repo_id, opts)
  def repo_releases(repo_id, opts) when is_integer(repo_id) do
    {params, opts} = Keyword.split(opts, [:release_type, :search])
    DB.all(DBQueryable.query({__MODULE__, :repo_releases_query}, [repo_id, Map.new(params)], opts))
  end

  @doc """
  Returns the number of releases for the given `repo`.
  """
  @spec count_repo_releases(Repo.t | pos_integer) :: non_neg_integer()
  @spec count_repo_releases([Repo.t | pos_integer]) :: %{pos_integer => non_neg_integer}
  def count_repo_releases(%Repo{id: repo_id}), do: count_repo_releases(repo_id)
  def count_repo_releases(repo_id) when is_integer(repo_id) do
    DB.one(query(:count_query, [repo_id, :releases]))
  end

  def count_repo_releases(repos) when is_list(repos) do
    repo_ids =
      Enum.map(repos, fn
        %Repo{id: repo_id} ->
          repo_id
        repo_id when is_integer(repo_id) ->
          repo_id
      end)
    count_map =
      query(:count_query, [repo_ids, :releases])
      |> DB.all()
      |> Map.new()
    Map.new(repo_ids, &{&1, Map.get(count_map, &1, 0)})
  end

  #
  # Callbacks
  #
  @impl true

  def query(:release_query, [ids]) when is_list(ids) do
    from(r in Release, as: :release, where: r.id in ^ids)
  end

  def query(:release_query, [id]) when is_integer(id) do
    from(r in Release, as: :release, where: r.id == ^id)
  end

  def query(:count_query, [repo_id, :releases]) when is_integer(repo_id) do
    from(r in Release, where: r.repo_id == ^repo_id, select: count(r))
  end

  def query(:count_query, [repo_ids, :releases]) when is_list(repo_ids) do
    from(r in Release, where: r.repo_id in ^repo_ids, group_by: r.repo_id, select: {r.repo_id, count(r)})
  end

  def query(:repo_releases_query, [repo_id, _opts]) when is_integer(repo_id) do
    from(r in Release, where: r.repo_id == ^repo_id)
  end

  @impl true
  def alter_query(query,  _viewer), do: query

  @impl true
  def preload_query(query, preloads, _viewer), do: preload(query, [], ^preloads)
end
