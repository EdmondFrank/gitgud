defmodule GitGud.PersonalAccessTokenQuery do
  @moduledoc """
  Conveniences for personal access token related queries.

  See `guides/MCP.md` §9 for the token model and the scope gate that consumes
  `authenticate/1`.
  """

  @behaviour GitGud.DBQueryable

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GitGud.DB
  alias GitGud.DBQueryable
  alias GitGud.PersonalAccessToken
  alias GitGud.User

  @doc """
  Returns a personal access token for the given `id`.
  """
  @spec by_id(pos_integer, keyword) :: PersonalAccessToken.t() | nil
  def by_id(id, opts \\ []) do
    DB.one(DBQueryable.query({__MODULE__, :personal_access_token_query}, [id], opts))
  end

  @doc """
  Returns the personal access token matching the lookup `prefix` of a presented
  token, or `nil`.

  The prefix is unique-indexed, so this is an O(1) lookup; the caller still has
  to verify the full token (see `GitGud.PersonalAccessToken.matches?/2`).
  """
  @spec by_prefix(binary, keyword) :: PersonalAccessToken.t() | nil
  def by_prefix(prefix, opts \\ []) when is_binary(prefix) do
    DB.one(DBQueryable.query({__MODULE__, :personal_access_token_query}, [prefix], opts))
  end

  def by_prefix(_prefix, _opts), do: nil

  @doc """
  Returns all personal access tokens belonging to `user`.
  """
  @spec user_tokens(User.t(), keyword) :: [PersonalAccessToken.t()]
  def user_tokens(%User{} = user, opts \\ []) do
    opts = Keyword.put_new(opts, :viewer, user)
    DB.all(DBQueryable.query({__MODULE__, :user_personal_access_tokens_query}, [user.id], opts))
  end

  @doc """
  Authenticates the presented `plaintext` token.

  Returns `{:ok, token}` for a token that exists, matches and is active (neither
  revoked nor expired); otherwise returns `{:error, :invalid_token}`.
  """
  @spec authenticate(binary) :: {:ok, PersonalAccessToken.t()} | {:error, :invalid_token}
  def authenticate(plaintext) when is_binary(plaintext) do
    with prefix when is_binary(prefix) <- PersonalAccessToken.prefix(plaintext),
         %PersonalAccessToken{} = token <- by_prefix(prefix),
         true <- PersonalAccessToken.matches?(token, plaintext),
         true <- PersonalAccessToken.active?(token) do
      {:ok, token}
    else
      _other -> {:error, :invalid_token}
    end
  end

  def authenticate(_plaintext), do: {:error, :invalid_token}

  @doc """
  Records that `token` was used by updating its `:last_used_at` timestamp.
  """
  @spec touch(PersonalAccessToken.t()) ::
          {:ok, PersonalAccessToken.t()} | {:error, Ecto.Changeset.t()}
  def touch(%PersonalAccessToken{} = token) do
    DB.update(change(token, last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)))
  end

  #
  # Callbacks
  #

  @impl true
  def query(:personal_access_token_query, [id]) when is_integer(id) do
    from(t in PersonalAccessToken, as: :personal_access_token, where: t.id == ^id)
  end

  def query(:personal_access_token_query, [prefix]) when is_binary(prefix) do
    from(t in PersonalAccessToken, as: :personal_access_token, where: t.token_prefix == ^prefix)
  end

  def query(:user_personal_access_tokens_query, [user_id]) when is_integer(user_id) do
    from(t in PersonalAccessToken, as: :personal_access_token, where: t.user_id == ^user_id)
  end

  @impl true
  def alter_query(query, _viewer), do: query

  @impl true
  def preload_query(query, [], _viewer), do: query

  def preload_query(query, [preload | tail], viewer) do
    query
    |> join_preload(preload, viewer)
    |> preload_query(tail, viewer)
  end

  #
  # Helpers
  #

  defp join_preload(query, :user, _viewer) do
    query
    |> join(:left, [personal_access_token: t], u in assoc(t, :user), as: :user)
    |> preload([user: u], user: u)
  end

  defp join_preload(query, preload, _viewer) do
    preload(query, ^preload)
  end
end
