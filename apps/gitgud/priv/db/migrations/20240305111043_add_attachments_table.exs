defmodule GitGud.DB.Migrations.AddAttachmentsTable do
  use Ecto.Migration

  def change do
    create table(:attachments) do
      add :key, :string, null: false
      add :filename, :string, null: false
      add :byte_size, :bigint, null: false
      add :service_name, :string, null: false
      add :metadata, :text
      add :checksum, :string
      add :content_type, :string
      add :attachable_id, :integer
      add :attachable_type, :string
      timestamps()
    end
  end
end
