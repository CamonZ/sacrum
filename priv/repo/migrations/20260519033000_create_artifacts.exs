defmodule Sacrum.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  def change do
    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :artifact_type, :string, null: false
      add :artifact_state, :string, null: false
      add :visibility, :string, null: false
      add :redaction_state, :string, null: false
      add :title, :string
      add :content, :text
      add :data, :map, null: false, default: %{}
      add :storage_ref, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifacts, [:project_id, :visibility, :redaction_state, :inserted_at])
    create index(:artifacts, [:user_id, :project_id, :inserted_at])

    create constraint(:artifacts, :artifacts_artifact_state_check,
             check:
               "artifact_state IN ('draft', 'pending_approval', 'approved', 'applied', 'rejected')"
           )

    create constraint(:artifacts, :artifacts_visibility_check,
             check: "visibility IN ('public', 'internal')"
           )

    create constraint(:artifacts, :artifacts_redaction_state_check,
             check: "redaction_state IN ('not_needed', 'redacted', 'blocked')"
           )
  end
end
