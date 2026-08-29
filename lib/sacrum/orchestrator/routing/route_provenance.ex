defmodule Sacrum.Orchestrator.Routing.RouteProvenance do
  @moduledoc """
  Resolves the completed execution that supplied a deterministic route input.

  A TaskRun cursor is the only runtime provenance source.  This deliberately
  does not select a task-global "latest completed" execution: unrelated runs,
  retries, and later work on another branch must not change a route decision.
  """

  alias Sacrum.Orchestrator.TaskRuns.Lookup
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

  @type provenance :: %{
          task_run: Sacrum.Repo.Schemas.TaskRun.t(),
          source_execution: StepExecution.t(),
          source_step: WorkflowStep.t(),
          route_step: WorkflowStep.t()
        }

  @type error ::
          :route_provenance_missing_task_run
          | :task_run_not_found
          | :route_provenance_missing_cursor
          | :route_provenance_cursor_execution_not_found
          | :route_provenance_source_step_not_found
          | :route_provenance_source_not_in_workflow
          | :route_provenance_no_incoming_transition

  @doc """
  Resolves the active TaskRun's completed cursor and proves that its source
  step is an incoming edge to `route_step` in the already loaded graph.

  The returned map is intentionally reused by context construction and the
  atomic route commit so neither phase can independently choose another input.
  """
  @spec resolve(map(), WorkflowStep.t()) :: {:ok, provenance()} | {:error, error()}
  def resolve(%{task_run_id: nil}, _route_step), do: {:error, :route_provenance_missing_task_run}

  def resolve(data, %WorkflowStep{} = route_step) do
    with {:ok, task_run} <- fetch_task_run(data),
         {:ok, source_execution} <- fetch_cursor_execution(task_run, data),
         {:ok, source_step} <- fetch_source_step(source_execution, data),
         :ok <- validate_incoming_edge(data, source_step.id, route_step.id) do
      {:ok,
       %{
         task_run: task_run,
         source_execution: source_execution,
         source_step: source_step,
         route_step: route_step
       }}
    end
  end

  defp fetch_task_run(data) do
    Lookup.fetch_for_task(data.user_id, data.project_id, data.task.id, data.task_run_id)
  end

  defp fetch_cursor_execution(%{latest_step_execution_id: nil}, _data),
    do: {:error, :route_provenance_missing_cursor}

  defp fetch_cursor_execution(task_run, data) do
    execution =
      Repo.get_by(StepExecution,
        id: task_run.latest_step_execution_id,
        user_id: data.user_id,
        project_id: data.project_id,
        task_id: data.task.id,
        task_run_id: task_run.id,
        workflow_id: data.task.workflow_id,
        status: "completed"
      )

    case execution do
      %StepExecution{} = execution -> {:ok, execution}
      nil -> {:error, :route_provenance_cursor_execution_not_found}
    end
  end

  defp fetch_source_step(%StepExecution{step_id: nil}, _data),
    do: {:error, :route_provenance_source_step_not_found}

  defp fetch_source_step(%StepExecution{step_id: step_id}, data) do
    case Map.get(data.steps, step_id) do
      %WorkflowStep{workflow_id: workflow_id} = source_step
      when workflow_id == data.task.workflow_id ->
        {:ok, source_step}

      %WorkflowStep{} ->
        {:error, :route_provenance_source_not_in_workflow}

      nil ->
        {:error, :route_provenance_source_step_not_found}
    end
  end

  defp validate_incoming_edge(data, source_step_id, route_step_id) do
    if route_step_id in Map.get(data.transitions, source_step_id, []) do
      :ok
    else
      {:error, :route_provenance_no_incoming_transition}
    end
  end
end
