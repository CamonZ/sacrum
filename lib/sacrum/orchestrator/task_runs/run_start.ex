defmodule Sacrum.Orchestrator.TaskRuns.RunStart do
  @moduledoc """
  Emits the initial pipeline position for newly created TaskRuns.
  """

  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.{Task, TaskRun}

  @spec broadcast_step_position(TaskRun.t(), Task.t()) :: :ok
  def broadcast_step_position(%TaskRun{} = task_run, %Task{current_step_id: step_id} = task)
      when is_binary(step_id) do
    Broadcaster.broadcast_task_run_step_changed(task_run, task, nil, step_id)
  end

  def broadcast_step_position(_task_run, _task), do: :ok
end
