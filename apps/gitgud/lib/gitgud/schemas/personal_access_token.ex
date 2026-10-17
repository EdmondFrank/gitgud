defmodule GitGud.PersonalAccessToken do
  @moduledoc """
  Personal access token schema and helper functions.

  A `GitGud.PersonalAccessToken` is a long-lived, user-scoped credential used to
  authenticate machine clients (such as the gitfrank MCP server) without
  embedding a password. Tokens are high-entropy random strings, so only a
  SHA-256 hash (and a short lookup prefix) is stored; the plaintext is returned
  **once** at creation time.

  See `guides/MCP.md` §9 for the design and the scope model.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GitGud.DB
  alias GitGud.User

  @scopes ~w(user:read repo:read repo:write issue:read issue:write review:write)
  @token_prefix "gf_"
  @lookup_length 12
  @token_bytes 32

  schema "personal_access_tokens" do
    belongs_to :user, User
    field :name, :string
    field :token_prefix, :string
    field :token_hash, :binary
    field :scopes, {:array, :string}, default: []
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    timestamps()
  end

  @type t :: %__MODULE__{
          id: pos_integer,
          user_id: pos_integer,
          user: User.t(),
          name: binary,
          token_prefix: binary,
          token_hash: binary,
          scopes: [binary],
          last_used_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  @doc "Returns the token prefix (`gf_`)."
  @spec token_prefix :: binary
  def token_prefix, do: @token_prefix

  @doc "Returns the list of valid scopes."
  @spec scopes :: [binary]
  def scopes, do: @scopes

  @doc """
  Creates a new personal access token for `user`.

  Returns `{:ok, {token, plaintext}}`; `plaintext` is the only time the raw
  token is available — only its prefix and hash are persisted.
  """
  @spec create(User.t(), map | keyword) :: {:ok, {t, binary}} | {:error, Ecto.Changeset.t()}
  def create(%User{} = user, params) do
    {token, plaintext} = build(user)

    case DB.insert(changeset(token, Map.new(params))) do
      {:ok, token} -> {:ok, {token, plaintext}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Similar to `create/2`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec create!(User.t(), map | keyword) :: {t, binary}
  def create!(%User{} = user, params) do
    case create(user, params) do
      {:ok, result} ->
        result

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: changeset.action, changeset: changeset
    end
  end

  @doc """
  Revokes the given `token`.
  """
  @spec revoke(t) :: {:ok, t} | {:error, Ecto.Changeset.t()}
  def revoke(%__MODULE__{} = token), do: DB.update(revoke_changeset(token))

  @doc """
  Similar to `revoke/1`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec revoke!(t) :: t
  def revoke!(%__MODULE__{} = token) do
    case revoke(token) do
      {:ok, token} ->
        token

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: changeset.action, changeset: changeset
    end
  end

  @doc """
  Deletes the given `token`.
  """
  @spec delete(t) :: {:ok, t} | {:error, Ecto.Changeset.t()}
  def delete(%__MODULE__{} = token), do: DB.delete(token)

  @doc """
  Similar to `delete/1`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec delete!(t) :: t
  def delete!(%__MODULE__{} = token), do: DB.delete!(token)

  @doc """
  Returns `true` if the token is neither revoked nor expired; otherwise returns `false`.
  """
  @spec active?(t) :: boolean
  def active?(%__MODULE__{revoked_at: revoked_at, expires_at: expires_at}) do
    is_nil(revoked_at) &&
      (is_nil(expires_at) || DateTime.compare(expires_at, DateTime.utc_now()) == :gt)
  end

  @doc """
  Returns the `#{@lookup_length}`-character lookup prefix of `token`, or `nil`.

  The prefix is stored (unique-indexed) so a presented token can be resolved to
  a single row with an O(1) lookup before the constant-time hash comparison.
  """
  @spec prefix(binary) :: binary | nil
  def prefix(token) when is_binary(token) and byte_size(token) >= @lookup_length do
    if String.starts_with?(token, @token_prefix), do: binary_part(token, 0, @lookup_length)
  end

  def prefix(_token), do: nil

  @doc "Returns the SHA-256 hash of `token`."
  @spec hash(binary) :: binary
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc """
  Returns `true` if `plaintext` matches the stored `token`, compared in constant time.
  """
  @spec matches?(t, binary) :: boolean
  def matches?(%__MODULE__{token_hash: hash}, plaintext) when is_binary(plaintext) do
    :crypto.hash_equals(hash, hash(plaintext))
  end

  def matches?(_token, _plaintext), do: false

  @doc """
  Returns a changeset for the given `params`.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = token, params \\ %{}) do
    token
    |> cast(params, [:name, :scopes, :expires_at])
    |> validate_required([:name, :token_prefix, :token_hash])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_scopes()
    |> unique_constraint(:token_prefix)
  end

  @doc false
  @spec revoke_changeset(t) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{} = token) do
    change(token, revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  #
  # Helpers
  #

  # Validates the resulting `:scopes` value rather than the cast change, because
  # `Ecto.Changeset.cast/3` discards an empty list for array fields (and an
  # omitted key produces no change at all).
  defp validate_scopes(changeset) do
    scopes = get_field(changeset, :scopes) || []
    invalid = Enum.reject(scopes, &(&1 in @scopes))

    cond do
      scopes == [] ->
        add_error(changeset, :scopes, "can't be blank")

      invalid != [] ->
        add_error(changeset, :scopes, "contains invalid scope(s): #{Enum.join(invalid, ", ")}")

      true ->
        changeset
    end
  end

  defp build(%User{id: user_id}) do
    plaintext =
      @token_prefix <>
        Base.encode32(:crypto.strong_rand_bytes(@token_bytes), case: :lower, padding: false)

    {%__MODULE__{user_id: user_id, token_prefix: prefix(plaintext), token_hash: hash(plaintext)},
     plaintext}
  end
end
