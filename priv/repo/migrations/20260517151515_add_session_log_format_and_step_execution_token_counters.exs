defmodule Sacrum.Repo.Migrations.AddSessionLogFormatAndStepExecutionTokenCounters do
  use Ecto.Migration

  def change do
    alter table(:session_logs) do
      add :format, :string, null: false, default: "anthropic"
    end

    create constraint(:session_logs, :session_logs_format_check,
             check: "format IN ('openai', 'anthropic')"
           )

    alter table(:step_executions) do
      add :session_input_tokens, :integer
      add :session_cache_read_input_tokens, :integer
      add :session_output_tokens, :integer
      add :session_total_tokens, :integer
      add :context_window_input_tokens, :integer
      add :context_window_cache_read_input_tokens, :integer
      add :context_window_total_tokens, :integer
    end
  end
end
