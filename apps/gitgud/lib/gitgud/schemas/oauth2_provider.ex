defmodule GitGud.OAuth2.Provider do
  @moduledoc """
  OAuth2.0 provider schema and helper functions.
  """

  use Ecto.Schema

  alias GitGud.DB
  alias GitGud.Account

  import Ecto.Changeset

  schema "oauth2_providers" do
    belongs_to :account, Account
    field :provider, :string
    field :provider_id, :integer
    field :token, :string
    timestamps()
  end

  @type t :: %__MODULE__{
    id: pos_integer,
    account_id: pos_integer,
    account: Account.t,
    provider: binary,
    provider_id: pos_integer,
    token: binary,
    inserted_at: NaiveDateTime.t,
    updated_at: NaiveDateTime.t
  }

  @doc """
  Creates a new OAuth2.0 provider with the given `params`.

  ```elixir
  {:ok, provider} = GitGud.OAuth2.Provider.create(account, provider: "github", provider_id: 12345, token: "2c0d6d13ca2e34ac557e181373f120d15c4fdd21")
  ```

  This function validates the given `params` using `changeset/2`.
  """
  @spec create(Account.t, map|keyword) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def create(account, params) do
    DB.insert(changeset(%__MODULE__{account_id: account.id}, Map.new(params)))
  end

  @doc """
  Similar to `create/2`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec create!(Account.t, map|keyword) :: t
  def create!(account, params) do
    DB.insert!(changeset(%__MODULE__{account_id: account.id}, Map.new(params)))
  end

  @doc """
  Deletes the given OAuth2.0 `provider`.
  """
  @spec delete(t) :: {:ok, t} | {:error, Ecto.Changeset.t}
  def delete(%__MODULE__{} = provider) do
    DB.delete(provider)
  end

  @doc """
  Similar to `delete!/1`, but raises an `Ecto.InvalidChangesetError` if an error occurs.
  """
  @spec delete!(t) :: t
  def delete!(%__MODULE__{} = provider) do
    DB.delete!(provider)
  end

  @doc """
  Returns an authentication provider changeset for the given `params`.
  """
  @spec changeset(t, map) :: Ecto.Changeset.t
  def changeset(%__MODULE__{} = provider, params \\ %{}) do
    provider
    |> cast(params, [:provider, :provider_id, :token])
    |> validate_required([:provider, :provider_id, :token])
    |> unique_constraint(:provider_id, name: :authentication_providers_provider_provider_id_index)
  end
end
