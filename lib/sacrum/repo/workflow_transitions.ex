defmodule Sacrum.Repo.WorkflowTransitions do
  @moduledoc """
  CRUD operations for workflow-to-workflow transitions.

  ## Error Contract

  - `get/1` returns `{:ok, transition}` or `{:error, :not_found}`
  - `get!/1` returns transition or raises
  - `get_by/1` returns `{:ok, transition}` or `{:error, :not_found}`
  - `all/0` returns `[transition]`
  - `insert/1` returns `{:ok, transition}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, transition}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. The `list_for_project/1` function automatically
  preloads `:from_workflow` and `:to_workflow` associations.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.WorkflowTransition

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition
  alias Sacrum.Routing.RouteValidator

  @spec list_for_project(String.t()) :: [WorkflowTransition.t()]
  @spec list_for_project(String.t(), String.t()) :: [WorkflowTransition.t()]
  def list_for_project(project_id) when is_binary(project_id) do
    Repo.all(
      from(t in WorkflowTransition,
        join: w in Workflow,
        on: w.id == t.from_workflow_id,
        where: w.project_id == ^project_id,
        preload: [:from_workflow, :to_workflow],
        order_by: [asc: t.inserted_at]
      )
    )
  end

  def list_for_project(project_id, user_id) when is_binary(project_id) and is_binary(user_id) do
    Repo.all(
      from(t in WorkflowTransition,
        join: w in Workflow,
        on: w.id == t.from_workflow_id,
        where: w.project_id == ^project_id and t.user_id == ^user_id,
        preload: [:from_workflow, :to_workflow],
        order_by: [asc: t.inserted_at]
      )
    )
  end

  @doc """
  Insert a new workflow transition with user_id.
  Extracts from_workflow_id, to_workflow_id, and project_id from attrs.

  ## Validations
  """
  @spec insert(Ecto.Changeset.t()) ::
          {:ok, WorkflowTransition.t()} | {:error, Ecto.Changeset.t()}
  @spec insert(String.t(), map()) ::
          {:ok, WorkflowTransition.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def insert(%Ecto.Changeset{data: %WorkflowTransition{}} = changeset) do
    from_workflow_id = Ecto.Changeset.get_field(changeset, :from_workflow_id)
    to_workflow_id = Ecto.Changeset.get_field(changeset, :to_workflow_id)
    project_id = Ecto.Changeset.get_field(changeset, :project_id)

    result =
      Repo.transaction(fn ->
        with :ok <- RouteValidator.lock_project(project_id),
             route_ids_before <-
               RouteValidator.related_route_ids_for_workflows([from_workflow_id, to_workflow_id]),
             {:ok, transition} <- Repo.insert(changeset),
             route_ids_after <-
               RouteValidator.related_route_ids_for_workflows([
                 transition.from_workflow_id,
                 transition.to_workflow_id
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
    from_workflow_id = Map.get(attrs, "from_workflow_id") || Map.get(attrs, :from_workflow_id)
    to_workflow_id = Map.get(attrs, "to_workflow_id") || Map.get(attrs, :to_workflow_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    changeset =
      WorkflowTransition.create_changeset(
        %WorkflowTransition{
          user_id: user_id,
          from_workflow_id: from_workflow_id,
          to_workflow_id: to_workflow_id,
          project_id: project_id
        },
        attrs
      )

    insert(changeset)
  end

  defoverridable insert: 2

  @spec update(Ecto.Changeset.t()) ::
          {:ok, WorkflowTransition.t()} | {:error, Ecto.Changeset.t()}
  def update(%Ecto.Changeset{data: %WorkflowTransition{} = transition} = changeset) do
    updated_from_workflow_id = Ecto.Changeset.get_field(changeset, :from_workflow_id)
    updated_to_workflow_id = Ecto.Changeset.get_field(changeset, :to_workflow_id)

    result =
      Repo.transaction(fn ->
        with :ok <- RouteValidator.lock_project(transition.project_id),
             route_ids_before <-
               RouteValidator.related_route_ids_for_workflows([
                 transition.from_workflow_id,
                 transition.to_workflow_id
               ]),
             {:ok, updated_transition} <- Repo.update(changeset),
             route_ids_after <-
               RouteValidator.related_route_ids_for_workflows([
                 updated_from_workflow_id,
                 updated_to_workflow_id
               ]),
             :ok <- RouteValidator.revalidate_route_ids(route_ids_before ++ route_ids_after) do
          updated_transition
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    normalize_validation_error(result, changeset)
  end

  @spec delete(WorkflowTransition.t()) ::
          {:ok, WorkflowTransition.t()} | {:error, Ecto.Changeset.t()}
  def delete(%WorkflowTransition{} = transition) do
    result =
      Repo.transaction(fn ->
        with :ok <- RouteValidator.lock_project(transition.project_id),
             route_ids <-
               RouteValidator.related_route_ids_for_workflows([
                 transition.from_workflow_id,
                 transition.to_workflow_id
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
