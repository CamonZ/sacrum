defmodule Sacrum.Repo.Migrations.RequireHarnessSessionLogIngestion do
  use Ecto.Migration

  def up do
    alter table(:session_logs) do
      modify :format, :string, default: "harness", null: false
    end

    drop constraint(:session_logs, :session_logs_format_check)

    # NOT VALID retains historical provider/no-key rows without allowing new
    # writes to violate the harness-only contract. Do not validate until an
    # operator has inventoried and explicitly retained/migrated old data.
    execute "ALTER TABLE session_logs ADD CONSTRAINT session_logs_format_check CHECK (format = 'harness') NOT VALID"

    execute "ALTER TABLE session_logs ADD CONSTRAINT session_logs_logical_key_check CHECK (logical_key IS NOT NULL AND logical_key LIKE 'harness:_%' AND length(logical_key) <= 255) NOT VALID"
  end

  def down do
    drop constraint(:session_logs, :session_logs_logical_key_check)
    drop constraint(:session_logs, :session_logs_format_check)

    create constraint(:session_logs, :session_logs_format_check,
             check: "format IN ('openai', 'anthropic', 'harness')"
           )

    alter table(:session_logs) do
      modify :format, :string, default: "anthropic", null: false
    end
  end
end
