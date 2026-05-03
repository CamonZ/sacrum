defmodule Sacrum.Tasks.Status do
  @moduledoc """
  Derives task status from orchestrator state (StepExecution + DAG position).

  Status values: `:ready`, `:running`, `:waiting`, `:done`, `:failed`.

  Derivation rules (evaluated in order):
    * `:running` — latest StepExecution is `started` or `in_progress`
    * `:waiting` — latest StepExecution is `waiting` (a parent waiting on its
      children via a `wait_children` step)
    * `:failed`  — latest StepExecution is `failed` (the orchestrator FSM has
      reached its terminal `:failed` state and persisted this status before
      stopping)
    * `:done`    — latest StepExecution is `completed`, the current step is
      final (is_final=true), and the workflow is final (is_final=true)
    * `:ready`   — none of the above apply

  Tasks always have `workflow_id` and `current_step_id` set (NOT NULL,
  defaulted to the project's Backlog workflow at creation time), so there is
  no "unassigned" status.

  Task dependencies (blockers) are *not* part of status derivation. Dependencies
  are an informational relationship; they do not move a task into `:waiting`.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task, Workflow, WorkflowStep}

  @type status :: :ready | :running | :waiting | :failed | :done

  @preloads [
    :step_executions,
    :workflow,
    :current_step
  ]

  @spec derive(Task.t()) :: status()
  def derive(%Task{} = task) do
    task = Repo.preload(task, @preloads, force: true)
    latest = latest_step_execution(task)

    cond do
      running?(latest) -> :running
      waiting?(latest) -> :waiting
      failed?(latest) -> :failed
      done?(task, latest) -> :done
      ready?(task, latest) -> :ready
    end
  end

  defp running?(%StepExecution{status: status}) when status in ["started", "in_progress"],
    do: true

  defp running?(_), do: false

  defp waiting?(%StepExecution{status: "waiting"}), do: true
  defp waiting?(_), do: false

  defp failed?(%StepExecution{status: "failed"}), do: true
  defp failed?(_), do: false

  defp done?(
         %Task{
           current_step: %WorkflowStep{is_final: true},
           workflow: %Workflow{is_final: true}
         },
         %StepExecution{status: "completed"}
       ) do
    true
  end

  defp done?(_task, _latest), do: false

  # No active execution. "completed" reaches here only when done?/2 returned
  # false — i.e. more transitions remain — so the task is ready to advance.
  # Active states ("started", "in_progress", "waiting") are handled by the
  # earlier clauses in derive/1. "failed" is handled by failed?/1 above.
  defp ready?(_task, nil), do: true

  defp ready?(_task, %StepExecution{status: status})
       when status in ["pending", "cancelled", "completed"],
       do: true

  defp ready?(_task, _latest), do: false

  defp latest_step_execution(%Task{step_executions: executions}) do
    Enum.max_by(executions, & &1.inserted_at, DateTime, fn -> nil end)
  end

  @doc """
  Recompute and persist `task.status`. Returns `{:ok, task}` (unchanged if the
  derived value matches the column) or `{:error, changeset}`.
  """
  @spec refresh(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def refresh(%Task{} = task) do
    cs = put_status(Ecto.Changeset.change(task))

    if cs.changes == %{} do
      {:ok, cs.data}
    else
      Repo.update(cs)
    end
  end

  @doc """
  Chains the derived `status` into an existing changeset, so the caller can
  do a single `Repo.update/1` (or `Multi.update/3`) that writes the position
  change and the status change atomically.

  Derives against the post-change view of the task by applying the changeset
  before deriving.
  """
  @spec put_status(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def put_status(%Ecto.Changeset{} = changeset) do
    applied = Ecto.Changeset.apply_changes(changeset)
    Ecto.Changeset.put_change(changeset, :status, Atom.to_string(derive(applied)))
  end
end
