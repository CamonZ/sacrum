defmodule Sacrum.Repo.Migrations.RemoveChatTranscriptSpine do
  use Ecto.Migration

  @publication "sacrum_cdc_publication"

  def up do
    remove_chat_tables_from_publication()
    remove_chat_session_artifact_links()

    drop constraint(:artifact_links, :artifact_links_subject_type_check)

    create constraint(:artifact_links, :artifact_links_subject_type_check,
             check:
               "subject_type IN ('task', 'task_section', 'workflow', 'task_run', 'step_execution')"
           )

    drop_if_exists table(:chat_events)
    drop_if_exists table(:chat_messages)
    drop_if_exists table(:chat_sessions)
  end

  def down do
    drop constraint(:artifact_links, :artifact_links_subject_type_check)

    create constraint(:artifact_links, :artifact_links_subject_type_check,
             check:
               "subject_type IN ('task', 'task_section', 'chat_session', 'workflow', 'task_run', 'step_execution')"
           )

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

    add_chat_tables_to_publication()
  end

  defp remove_chat_tables_from_publication do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = '#{@publication}' AND tablename = 'chat_events') THEN
        ALTER PUBLICATION #{@publication} DROP TABLE chat_events;
      END IF;

      IF EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = '#{@publication}' AND tablename = 'chat_messages') THEN
        ALTER PUBLICATION #{@publication} DROP TABLE chat_messages;
      END IF;

      IF EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname = '#{@publication}' AND tablename = 'chat_sessions') THEN
        ALTER PUBLICATION #{@publication} DROP TABLE chat_sessions;
      END IF;
    END $$;
    """)
  end

  defp add_chat_tables_to_publication do
    execute("ALTER TABLE IF EXISTS chat_sessions REPLICA IDENTITY FULL")
    execute("ALTER TABLE IF EXISTS chat_messages REPLICA IDENTITY FULL")
    execute("ALTER TABLE IF EXISTS chat_events REPLICA IDENTITY FULL")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{@publication}') THEN
        ALTER PUBLICATION #{@publication}
          ADD TABLE chat_sessions, chat_messages, chat_events;
      END IF;
    END $$;
    """)
  end

  defp remove_chat_session_artifact_links do
    execute("DELETE FROM artifact_links WHERE subject_type = 'chat_session'")
  end
end
