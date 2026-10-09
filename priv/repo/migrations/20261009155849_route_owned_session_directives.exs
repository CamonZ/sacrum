defmodule Sacrum.Repo.Migrations.RouteOwnedSessionDirectives do
  @moduledoc """
  Moves session control from llm_inference step config to route decisions.

  Executions record the conversation they belong to
  (`conversation_root_execution_id`) and the execution they forked
  (`forked_from_execution_id`) instead of an author-chosen `session_name`, and
  the step-level `session` config is removed from stored step and execution
  configs. There is no compatibility path: rolling back restores the columns
  but not the removed names or configs.
  """

  use Ecto.Migration

  def up do
    drop_if_exists index(:step_executions, [:task_run_id, :session_name, :inserted_at])

    alter table(:step_executions) do
      remove :session_name

      add :conversation_root_execution_id,
          references(:step_executions, type: :binary_id, on_delete: :nilify_all)

      add :forked_from_execution_id,
          references(:step_executions, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:step_executions, [:task_run_id, :conversation_root_execution_id, :inserted_at],
             where: "conversation_root_execution_id IS NOT NULL"
           )

    create index(:step_executions, [:forked_from_execution_id],
             where: "forked_from_execution_id IS NOT NULL"
           )

    execute """
    UPDATE workflow_steps SET config = config - 'session'
    WHERE step_type = 'llm_inference' AND config ? 'session'
    """

    execute """
    UPDATE step_executions SET config = config - 'session'
    WHERE step_type = 'llm_inference' AND config ? 'session'
    """
  end

  def down do
    drop index(:step_executions, [:forked_from_execution_id])
    drop index(:step_executions, [:task_run_id, :conversation_root_execution_id, :inserted_at])

    alter table(:step_executions) do
      remove :forked_from_execution_id
      remove :conversation_root_execution_id
      add :session_name, :string
    end

    create index(:step_executions, [:task_run_id, :session_name, :inserted_at],
             where: "session_name IS NOT NULL"
           )
  end
end
