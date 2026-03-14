defmodule Sacrum.Orchestrator.ExecutionDispatcher do
  @moduledoc """
  Handles creation and dispatching of step executions.

  Creates pending StepExecution records and broadcasts run_step events
  to the daemon. Uses a prompt-based architecture where the ticket ID
  acts as a token — the step prompt is rendered with the task's short_id
  interpolated into {ticket_id} placeholders.

  Used by both the GraphQL runStep resolver and the TaskOrchestrator to
  ensure consistent execution dispatch behavior.
  """

  alias Sacrum.Accounts
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution

  @doc """
  Creates and dispatches a step execution.

  Fetches the step, creates a pending StepExecution, renders the prompt
  by interpolating the task's short_id into {ticket_id} placeholders,
  broadcasts the run_step event, and returns the execution.

  Returns:
    - {:ok, execution} on success
    - {:error, reason} on failure
  """
  @spec create_and_dispatch(String.t(), struct(), String.t()) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_dispatch(user_id, task, step_id) do
    with {:ok, step} <- fetch_step(user_id, step_id),
         {:ok, execution} <- insert_execution(user_id, task, step) do
      rendered_prompt = render_prompt(step.prompt, task.short_id)

      Broadcaster.broadcast_run_step(
        %{execution: execution, step: step, task: task, rendered_prompt: rendered_prompt},
        task.project_id
      )

      {:ok, execution}
    end
  end

  defp fetch_step(user_id, step_id) do
    Accounts.WorkflowSteps.get_by(user_id,
      conditions: [id: step_id]
    )
  end

  defp insert_execution(user_id, task, step) do
    attrs = %{
      task_id: task.id,
      workflow_id: step.workflow_id,
      step_name: step.name,
      status: "pending",
      project_id: task.project_id
    }

    Accounts.StepExecutions.insert(user_id, attrs)
  end

  defp render_prompt(nil, _short_id), do: ""

  defp render_prompt(prompt, short_id) when is_binary(prompt) and is_binary(short_id) do
    String.replace(prompt, "{ticket_id}", short_id)
  end
end
