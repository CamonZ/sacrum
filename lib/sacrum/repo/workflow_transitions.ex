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
  alias Sacrum.Repo.RouteValidation
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition

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
    affected =
      Enum.filter(
        [
          Ecto.Changeset.get_field(changeset, :from_workflow_id),
          Ecto.Changeset.get_field(changeset, :to_workflow_id)
        ],
        &is_binary/1
      )

    RouteValidation.mutate(affected, changeset, fn -> Repo.insert(changeset) end)
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
    affected =
      Enum.filter(
        [
          transition.from_workflow_id,
          transition.to_workflow_id,
          Ecto.Changeset.get_field(changeset, :from_workflow_id),
          Ecto.Changeset.get_field(changeset, :to_workflow_id)
        ],
        &is_binary/1
      )

    RouteValidation.mutate(affected, changeset, fn -> Repo.update(changeset) end)
  end

  @spec delete(WorkflowTransition.t()) ::
          {:ok, WorkflowTransition.t()} | {:error, Ecto.Changeset.t()}
  def delete(%WorkflowTransition{} = transition) do
    affected = [transition.from_workflow_id, transition.to_workflow_id]

    RouteValidation.mutate(affected, transition, fn -> Repo.delete(transition) end)
  end
end
