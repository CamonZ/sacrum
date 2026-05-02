defmodule Sacrum.Tasks.Status do
  @moduledoc """
  Derives task status from orchestrator state (StepExecution + DAG position).

  Status values: `:ready`, `:running`, `:waiting`, `:done`.

  Derivation rules (evaluated in order):
    * `:running` — latest StepExecution is `started` or `in_progress`
    * `:waiting` — latest StepExecution is `waiting` (a parent waiting on its
      children via a `wait_children` step)
    * `:done`    — latest StepExecution is `completed`, the current step is
      final, the step has no outgoing step transitions, and the workflow has
      no outgoing workflow transitions
    * `:ready`   — `current_step_id` is set and none of the above apply

  Task dependencies (blockers) are *not* part of status derivation. Dependencies
  are an informational relationship; they do not move a task into `:waiting`.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task, Workflow, WorkflowStep}

  @type status :: :ready | :running | :waiting | :done

  @preloads [
    :step_executions,
    current_step: :transitions,
    workflow: :transitions
  ]

  @spec derive(Task.t()) :: status()
  def derive(%Task{} = task) do
    task = Repo.preload(task, @preloads, force: true)
    latest = latest_step_execution(task)

    cond do
      running?(latest) -> :running
      waiting?(latest) -> :waiting
      done?(task, latest) -> :done
      task.current_step_id != nil -> :ready
      true -> :waiting
    end
  end

  defp running?(%StepExecution{status: status}) when status in ["started", "in_progress"],
    do: true

  defp running?(_), do: false

  defp waiting?(%StepExecution{status: "waiting"}), do: true
  defp waiting?(_), do: false

  defp done?(
         %Task{
           current_step: %WorkflowStep{is_final: true, transitions: step_txs},
           workflow: %Workflow{transitions: wf_txs}
         },
         %StepExecution{status: "completed"}
       ) do
    Enum.empty?(step_txs) and Enum.empty?(wf_txs)
  end

  defp done?(_task, _latest), do: false

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
