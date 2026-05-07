defmodule Sacrum.Tasks.Status do
  @moduledoc """
  Derives the compatibility task queue status from durable task state.

  New derivations return `:ready` or `:done`.

  The `tasks.status` column still accepts historical `running` and `waiting`
  values so existing filters and clients have a compatibility path, but this
  module no longer writes active automation lifecycle states. Use
  `TaskRun.status` for run lifecycle and `StepExecution.status` for individual
  attempt history.

  Derivation rules:
    * `:done`  — `completed_at` has been stamped by task completion
    * `:ready` — all other task workflow positions

  Task dependencies (blockers) are *not* part of status derivation. Dependencies
  are an informational relationship; they do not move a task into `:waiting`.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task

  @type status :: :ready | :done

  @spec derive(Task.t()) :: status()
  def derive(%Task{completed_at: completed_at}) when not is_nil(completed_at), do: :done
  def derive(%Task{}), do: :ready

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
