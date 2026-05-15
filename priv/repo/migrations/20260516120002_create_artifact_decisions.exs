defmodule Sacrum.Repo.Migrations.CreateArtifactDecisions do
  use Ecto.Migration

  def change do
    create table(:artifact_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :artifact_id, references(:artifacts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_type, :string
      add :subject_id, :binary_id

      add :decision_kind, :string, null: false

      add :decided_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all),
        null: false

      add :comments, :text
      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifact_decisions, [:artifact_id, :inserted_at])
    create index(:artifact_decisions, [:decided_by_user_id])
    create index(:artifact_decisions, [:subject_type, :subject_id])

    create constraint(:artifact_decisions, :artifact_decisions_decision_kind_check,
             check:
               "decision_kind IN ('approved', 'rejected', 'rejected_with_comments', 'needs_revision', 'pending_review')"
           )
  end
end
