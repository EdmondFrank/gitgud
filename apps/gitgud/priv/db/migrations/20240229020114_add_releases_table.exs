defmodule GitGud.DB.Migrations.AddReleasesTable do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE releases_types AS ENUM ('normal', 'preview')",
      "DROP TYPE releases_types"
    )

    create table("releases") do
      add :title, :string, null: false
      add :description, :text, null: false
      add :author_id, references("users", on_delete: :delete_all), null: false
      add :repo_id, references("repositories", on_delete: :delete_all), null: false
      add :release_type, :releases_types, null: false, default: "normal"
      add :tag_version, :string, null: false
      add :revision, :string, null: false
      timestamps()
    end
  end
end
