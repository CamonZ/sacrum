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
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Routing.RouteValidator

  @doc """
  Insert a new step transition with user_id.
  Extracts from_step_id, to_step_id, and project_id from attrs.
  """
  @spec insert(Ecto.Changeset.t()) :: {:ok, StepTransition.t()} | {:error, Ecto.Changeset.t()}
  @spec insert(String.t(), map()) ::
          {:ok, StepTransition.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def insert(%Ecto.Changeset{data: %StepTransition{}} = changeset) do
    from_step_id = Ecto.Changeset.get_field(changeset, :from_step_id)
    to_step_id = Ecto.Changeset.get_field(changeset, :to_step_id)
    project_id = Ecto.Changeset.get_field(changeset, :project_id)

    result =
      Repo.transaction(fn ->
        with :ok <- RouteValidator.lock_project(project_id),
             route_ids_before <-
               RouteValidator.related_route_ids_for_steps([from_step_id, to_step_id]),
             {:ok, transition} <- Repo.insert(changeset),
             route_ids_after <-
               RouteValidator.related_route_ids_for_steps([
                 transition.from_step_id,
                 transition.to_step_id
               ]),
             :ok <- RouteValidator.revalidate_route_ids(route_ids_before ++ route_ids_after) do
          transition
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    normalize_validation_error(result, changeset)
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
    updated_from_step_id = Ecto.Changeset.get_field(changeset, :from_step_id)
    updated_to_step_id = Ecto.Changeset.get_field(changeset, :to_step_id)

    result =
      Repo.transaction(fn ->
        with :ok <- RouteValidator.lock_project(transition.project_id),
             route_ids_before <-
               RouteValidator.related_route_ids_for_steps([
                 transition.from_step_id,
                 transition.to_step_id
               ]),
             {:ok, updated_transition} <- Repo.update(changeset),
             route_ids_after <-
               RouteValidator.related_route_ids_for_steps([
                 updated_from_step_id,
                 updated_to_step_id
               ]),
             :ok <- RouteValidator.revalidate_route_ids(route_ids_before ++ route_ids_after) do
          updated_transition
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    normalize_validation_error(result, changeset)
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
    result =
      Repo.transaction(fn ->
        with :ok <- RouteValidator.lock_project(transition.project_id),
             route_ids <-
               RouteValidator.related_route_ids_for_steps([
                 transition.from_step_id,
                 transition.to_step_id
               ]),
             {:ok, deleted_transition} <- Repo.delete(transition),
             :ok <- RouteValidator.revalidate_route_ids(route_ids) do
          deleted_transition
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    normalize_validation_error(result, transition)
  end

  defp normalize_validation_error({:ok, result}, _record), do: {:ok, result}

  defp normalize_validation_error({:error, %Ecto.Changeset{} = changeset}, _record),
    do: {:error, changeset}

  defp normalize_validation_error({:error, %{code: _code} = reason}, record) do
    {:error, RouteValidator.error_changeset(record, reason)}
  end

  defp normalize_validation_error({:error, reason}, _record), do: {:error, reason}
end
