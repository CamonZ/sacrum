defmodule Sacrum.Orchestrator.ExecutionDispatcher do
  @moduledoc """
  Handles creation and dispatching of step executions.

  Creates pending StepExecution records and broadcasts run_step events
  to the daemon. Used by both the GraphQL runStep resolver and the
  TaskOrchestrator to ensure consistent execution dispatch behavior.
  """

  alias Sacrum.Accounts
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution

  @doc """
  Creates and dispatches a step execution.

  Fetches the step (with workflow and transitions preloaded), creates a
  pending StepExecution with a context snapshot, broadcasts the run_step
  event, and returns the execution.

  Returns:
    - {:ok, execution} on success
    - {:error, reason} on failure
  """
  @spec create_and_dispatch(String.t(), struct(), String.t()) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_dispatch(user_id, task, step_id) do
    with {:ok, step} <- fetch_step(user_id, step_id),
         {:ok, execution} <- insert_execution(user_id, task, step) do
      Broadcaster.broadcast_run_step(
        execution,
        step,
        step.workflow,
        step.transitions,
        task.project_id
      )

      {:ok, execution}
    end
  end

  defp fetch_step(user_id, step_id) do
    Accounts.WorkflowSteps.get_by(user_id,
      conditions: [id: step_id],
      preloads: [:workflow, :transitions]
    )
  end

  defp insert_execution(user_id, task, step) do
    attrs = %{
      task_id: task.id,
      workflow_id: step.workflow_id,
      step_name: step.name,
      status: "pending",
      project_id: task.project_id,
      context: build_context(task)
    }

    Accounts.StepExecutions.insert(user_id, attrs)
  end

  defp build_context(task) do
    %{
      title: task.title,
      description: task.description,
      sections: build_sections_context(task.sections),
      code_refs: build_code_refs_context(task.code_refs)
    }
  end

  defp build_sections_context(sections) do
    Enum.map(sections, fn section ->
      %{
        section_type: section.section_type,
        content: section.content,
        section_order: section.section_order,
        done: section.done,
        code_refs: build_code_refs_context(section.code_refs)
      }
    end)
  end

  defp build_code_refs_context(code_refs) do
    Enum.map(code_refs, fn ref ->
      %{
        path: ref.path,
        line_start: ref.line_start,
        line_end: ref.line_end,
        name: ref.name,
        description: ref.description
      }
    end)
  end
end
