defmodule GitGud.DB.Migrations.CreatePersonalAccessTokens do
  use Ecto.Migration

  def change do
    create table(:personal_access_tokens) do
      add :user_id, references("users", on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :token_prefix, :string, null: false
      add :token_hash, :binary, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :last_used_at, :utc_datetime
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      timestamps()
    end

    create unique_index("personal_access_tokens", [:token_prefix])
    create index("personal_access_tokens", [:user_id])
  end
end
