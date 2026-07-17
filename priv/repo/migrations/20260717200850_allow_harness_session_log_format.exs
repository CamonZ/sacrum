defmodule Sacrum.Repo.Migrations.AllowHarnessSessionLogFormat do
  use Ecto.Migration

  def up do
    drop constraint(:session_logs, :session_logs_format_check)

    create constraint(:session_logs, :session_logs_format_check,
             check: "format IN ('openai', 'anthropic', 'harness')"
           )
  end

  def down do
    execute(down_guard_sql())

    drop constraint(:session_logs, :session_logs_format_check)

    create constraint(:session_logs, :session_logs_format_check,
             check: "format IN ('openai', 'anthropic')"
           )
  end

  def down_guard_sql do
    """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM session_logs WHERE format = 'harness') THEN
        RAISE EXCEPTION 'cannot restore session_logs_format_check while harness rows exist';
      END IF;
    END
    $$
    """
  end
end
