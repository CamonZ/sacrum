defmodule Sacrum.Repo.TaskWorkflows do
  @moduledoc """
  Workflow assignment and progression functions for tasks.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, Workflow, WorkflowStep, StepExecution, StepTransition}

  @doc """
  Assigns a workflow to a task, setting current_step_id to the workflow's initial step.
  Creates a StepExecution audit record for the initial step entry.
  """
  def assign_workflow(%Task{} = task, %Workflow{} = workflow) do
    workflow = Repo.preload(workflow, :workflow_steps)

    with {:ok, initial_step} <- resolve_initial_step(workflow) do
      Multi.new()
      |> Multi.update(:task, task_workflow_changeset(task, workflow.id, initial_step.id))
      |> Multi.insert(:step_execution, step_execution_attrs(task.id, workflow.id, initial_step))
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} -> {:ok, task}
        {:error, _op, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  @doc """
  Removes the workflow assignment from a task, clearing workflow_id and current_step_id.
  """
  def unassign_workflow(%Task{} = task) do
    task
    |> task_workflow_changeset(nil, nil)
    |> Repo.update()
  end

  @doc """
  Returns the current WorkflowStep for a task, or {:error, :no_current_step}.
  """
  def get_current_step(%Task{current_step_id: nil}), do: {:error, :no_current_step}

  def get_current_step(%Task{current_step_id: step_id}) do
    case Repo.get(WorkflowStep, step_id) do
      nil -> {:error, :not_found}
      step -> {:ok, step}
    end
  end

  @doc """
  Advances a task to the next step via a valid StepTransition.
  Creates a StepExecution audit record for the new step.

  If the task is on a final step and the workflow has an on_done_workflow,
  transitions to that workflow's initial step.
  """
  def advance_step(%Task{current_step_id: nil}), do: {:error, :no_current_step}

  def advance_step(%Task{} = task) do
    task = Repo.preload(task, [:workflow, current_step: []])

    transitions =
      from(t in StepTransition,
        where: t.from_step_id == ^task.current_step_id,
        preload: [:to_step]
      )
      |> Repo.all()

    case transitions do
      [] ->
        maybe_chain_workflow(task)

      [transition | _] ->
        to_step = transition.to_step

        Multi.new()
        |> Multi.update(:task, task_workflow_changeset(task, task.workflow_id, to_step.id))
        |> Multi.insert(:step_execution, step_execution_attrs(task.id, task.workflow_id, to_step))
        |> Repo.transaction()
        |> case do
          {:ok, %{task: task}} -> {:ok, task}
          {:error, _op, changeset, _changes} -> {:error, changeset}
        end
    end
  end

  @doc """
  Retreats a task to the previous step via a reverse StepTransition.
  Creates a StepExecution audit record for the new step.
  """
  def retreat_step(%Task{current_step_id: nil}), do: {:error, :no_current_step}

  def retreat_step(%Task{} = task) do
    reverse_transitions =
      from(t in StepTransition,
        where: t.to_step_id == ^task.current_step_id,
        preload: [:from_step]
      )
      |> Repo.all()

    case reverse_transitions do
      [] ->
        {:error, :no_retreat_transition}

      [transition | _] ->
        from_step = transition.from_step

        Multi.new()
        |> Multi.update(:task, task_workflow_changeset(task, task.workflow_id, from_step.id))
        |> Multi.insert(
          :step_execution,
          step_execution_attrs(task.id, task.workflow_id, from_step)
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{task: task}} -> {:ok, task}
          {:error, _op, changeset, _changes} -> {:error, changeset}
        end
    end
  end

  # Private helpers

  defp resolve_initial_step(%Workflow{initial_step_id: step_id})
       when not is_nil(step_id) do
    case Repo.get(WorkflowStep, step_id) do
      nil -> {:error, :initial_step_not_found}
      step -> {:ok, step}
    end
  end

  defp resolve_initial_step(%Workflow{workflow_steps: steps}) when is_list(steps) do
    case Enum.sort_by(steps, & &1.step_order) do
      [first | _] -> {:ok, first}
      [] -> {:error, :workflow_has_no_steps}
    end
  end

  defp task_workflow_changeset(task, workflow_id, step_id) do
    task
    |> Ecto.Changeset.change(%{workflow_id: workflow_id, current_step_id: step_id})
    |> Ecto.Changeset.foreign_key_constraint(:workflow_id)
    |> Ecto.Changeset.foreign_key_constraint(:current_step_id)
  end

  defp step_execution_attrs(task_id, workflow_id, step) do
    StepExecution.create_changeset(%StepExecution{}, %{
      task_id: task_id,
      workflow_id: workflow_id,
      step_name: step.name,
      status: "entered"
    })
  end

  defp maybe_chain_workflow(%Task{} = task) do
    workflow = Repo.preload(task.workflow, :on_done_workflow)

    case workflow.on_done_workflow do
      nil ->
        {:error, :no_transition}

      next_workflow ->
        next_workflow = Repo.preload(next_workflow, :workflow_steps)

        with {:ok, initial_step} <- resolve_initial_step(next_workflow) do
          Multi.new()
          |> Multi.update(
            :task,
            task_workflow_changeset(task, next_workflow.id, initial_step.id)
          )
          |> Multi.insert(
            :step_execution,
            step_execution_attrs(task.id, next_workflow.id, initial_step)
          )
          |> Repo.transaction()
          |> case do
            {:ok, %{task: task}} -> {:ok, task}
            {:error, _op, changeset, _changes} -> {:error, changeset}
          end
        end
    end
  end
end
