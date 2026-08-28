defmodule Sacrum.Repo.StepTransitions do
  @moduledoc """
  CRUD operations for step transitions within a workflow.

  ## Error Contract

  - `get/1` returns `{:ok, transition}` or `{:error, :not_found}`
  - `get!/1` returns transition or raises
  - `get_by/1` returns `{:ok, transition}` or `{:error, :not_found}`
  - `all/0` returns `[transition]`
  - `insert/1` returns `{:ok, transition}` or `{:error, changeset}` or `{:error, atom}`
  - `delete/1` returns `{:ok, transition}` or `{:error, changeset}`

  ## Domain-Specific Errors

  `insert/1` may return `{:error, atom}` for:
  - `:different_workflows` - when step transitions belong to different workflows
  - `:finish_step_cannot_have_outgoing_transition` - when the source step is a finish step
  - `:stop_step_requires_exactly_one_outgoing_transition` - when a stop step already has an outgoing transition

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.StepTransition

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.RouteValidation
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Schemas.WorkflowStep

  @doc """
  Insert a new step transition with user_id.
  Extracts from_step_id, to_step_id, and project_id from attrs.
  """
  @spec insert(Ecto.Changeset.t()) :: {:ok, StepTransition.t()} | {:error, Ecto.Changeset.t()}
  @spec insert(String.t(), map()) ::
          {:ok, StepTransition.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def insert(%Ecto.Changeset{data: %StepTransition{}} = changeset) do
    affected =
      changeset.data
      |> step_workflow_ids()
      |> Enum.concat(step_workflow_ids_after(changeset))

    RouteValidation.mutate(affected, changeset, fn -> Repo.insert(changeset) end)
  end

  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    from_step_id = Map.get(attrs, "from_step_id") || Map.get(attrs, :from_step_id)
    to_step_id = Map.get(attrs, "to_step_id") || Map.get(attrs, :to_step_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    with :ok <- validate_same_workflow(attrs),
         :ok <- validate_from_step_type(attrs),
         :ok <- validate_stop_step_cardinality(attrs) do
      changeset =
        StepTransition.create_changeset(
          %StepTransition{
            user_id: user_id,
            from_step_id: from_step_id,
            to_step_id: to_step_id,
            project_id: project_id
          },
          attrs
        )

      insert(changeset)
    end
  end

  defoverridable insert: 2

  @spec update(Ecto.Changeset.t()) :: {:ok, StepTransition.t()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{data: %StepTransition{} = transition} = changeset) do
    affected =
      transition
      |> step_workflow_ids()
      |> Enum.concat(step_workflow_ids_after(changeset))

    RouteValidation.mutate(affected, changeset, fn -> Repo.update(changeset) end)
  end

  defp validate_same_workflow(attrs) do
    from_id = attrs[:from_step_id] || attrs["from_step_id"]
    to_id = attrs[:to_step_id] || attrs["to_step_id"]

    if is_nil(from_id) or is_nil(to_id) do
      :ok
    else
      compare_step_workflows(from_id, to_id)
    end
  end

  defp validate_from_step_type(attrs) do
    from_id = attrs[:from_step_id] || attrs["from_step_id"]

    if is_nil(from_id) do
      :ok
    else
      case Repo.get(WorkflowStep, from_id) do
        %WorkflowStep{step_type: :finish} ->
          {:error, :finish_step_cannot_have_outgoing_transition}

        _step ->
          :ok
      end
    end
  end

  defp validate_stop_step_cardinality(attrs) do
    from_id = attrs[:from_step_id] || attrs["from_step_id"]

    case Repo.get(WorkflowStep, from_id) do
      %WorkflowStep{step_type: :stop} = step ->
        if Repo.exists?(from t in StepTransition, where: t.from_step_id == ^step.id) do
          {:error, :stop_step_requires_exactly_one_outgoing_transition}
        else
          :ok
        end

      _step ->
        :ok
    end
  end

  defp compare_step_workflows(from_id, to_id) do
    from_step = Repo.get(WorkflowStep, from_id)
    to_step = Repo.get(WorkflowStep, to_id)

    cond do
      is_nil(from_step) or is_nil(to_step) -> :ok
      from_step.workflow_id == to_step.workflow_id -> :ok
      true -> {:error, :different_workflows}
    end
  end

  @spec delete(StepTransition.t()) :: {:ok, StepTransition.t()} | {:error, Ecto.Changeset.t()}
  def delete(%StepTransition{} = transition) do
    RouteValidation.mutate(step_workflow_ids(transition), transition, fn ->
      Repo.delete(transition)
    end)
  end

  # Workflows whose configured routes a mutation of this transition can affect.
  defp step_workflow_ids(%StepTransition{from_step_id: from, to_step_id: to}) do
    from
    |> List.wrap()
    |> Enum.concat(List.wrap(to))
    |> workflow_ids_for_steps()
  end

  defp step_workflow_ids_after(changeset) do
    workflow_ids_for_steps([
      Ecto.Changeset.get_field(changeset, :from_step_id),
      Ecto.Changeset.get_field(changeset, :to_step_id)
    ])
  end

  defp workflow_ids_for_steps(step_ids) do
    case Enum.filter(step_ids, &is_binary/1) do
      [] -> []
      ids -> Repo.all(from(s in WorkflowStep, where: s.id in ^ids, select: s.workflow_id))
    end
  end
end
