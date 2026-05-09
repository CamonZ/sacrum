defmodule Sacrum.Repo.Migrations.CreateChatTranscriptSpine do
  use Ecto.Migration

  def change do
    create table(:chat_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :status, :string, null: false, default: "queued"
      add :session_kind, :string, null: false, default: "planning"
      add :started_at, :utc_datetime_usec
      add :ended_at, :utc_datetime_usec
      add :stop_requested_at, :utc_datetime_usec
      add :engine_kind, :string
      add :engine_session_ref, :string
      add :definition_ref, :string
      add :public_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:chat_sessions, [:project_id, :inserted_at])
    create index(:chat_sessions, [:user_id, :project_id, :inserted_at])

    create constraint(:chat_sessions, :chat_sessions_status_check,
             check:
               "status IN ('queued', 'running', 'waiting', 'cancelling', 'cancelled', 'completed', 'failed')"
           )

    create table(:chat_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :chat_session_id,
          references(:chat_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :role, :string, null: false
      add :content, :text, null: false
      add :content_format, :string, null: false, default: "plain"
      add :client_message_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:chat_messages, [:chat_session_id, :inserted_at])
    create index(:chat_messages, [:project_id, :inserted_at])
    create index(:chat_messages, [:user_id, :project_id, :inserted_at])

    create unique_index(:chat_messages, [:chat_session_id, :client_message_id],
             where: "client_message_id IS NOT NULL"
           )

    create constraint(:chat_messages, :chat_messages_role_check,
             check: "role IN ('user', 'assistant', 'status')"
           )

    create constraint(:chat_messages, :chat_messages_content_format_check,
             check: "content_format IN ('plain', 'markdown')"
           )

    create table(:chat_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :chat_session_id,
          references(:chat_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :event_type, :string, null: false
      add :visibility, :string, null: false, default: "public"
      add :public_payload, :map, null: false, default: %{}
      add :internal_payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:chat_events, [:chat_session_id, :visibility, :inserted_at])
    create index(:chat_events, [:project_id, :visibility, :inserted_at])
    create index(:chat_events, [:user_id, :project_id, :inserted_at])

    create constraint(:chat_events, :chat_events_visibility_check,
             check: "visibility IN ('public', 'internal')"
           )
  end
end
