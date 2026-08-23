defmodule Sacrum.Repo.WorkflowInitialStep do
  @moduledoc "Resolves a workflow's entry step without changing persisted state."

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Workflow, WorkflowStep}

  @type error :: :initial_step_not_found | :workflow_has_no_steps

  @spec resolve(Workflow.t()) :: {:ok, WorkflowStep.t()} | {:error, error()}
  def resolve(%Workflow{} = workflow) do
    query =
      from(s in WorkflowStep,
        where:
          s.workflow_id == ^workflow.id and
            s.project_id == ^workflow.project_id and
            s.user_id == ^workflow.user_id,
        order_by: [asc_nulls_last: s.step_order, asc: s.inserted_at, asc: s.id],
        limit: 1
      )

    case workflow.initial_step_id do
      nil ->
        case Repo.one(query) do
          nil -> {:error, :workflow_has_no_steps}
          step -> {:ok, step}
        end

      step_id ->
        case Repo.one(from(s in query, where: s.id == ^step_id)) do
          nil -> {:error, :initial_step_not_found}
          step -> {:ok, step}
        end
    end
  end
end
