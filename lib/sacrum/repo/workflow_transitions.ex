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

  def list_for_project(project_id) when is_binary(project_id) do
    from(t in WorkflowTransition,
      join: w in Workflow,
      on: w.id == t.from_workflow_id,
      where: w.project_id == ^project_id,
      preload: [:from_workflow, :to_workflow],
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  def list_for_project(project_id, user_id) when is_binary(project_id) and is_binary(user_id) do
    from(t in WorkflowTransition,
      join: w in Workflow,
      on: w.id == t.from_workflow_id,
      where: w.project_id == ^project_id and t.user_id == ^user_id,
      preload: [:from_workflow, :to_workflow],
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Insert a new workflow transition from attrs map.
  """
  def insert(attrs) when is_map(attrs) do
    %WorkflowTransition{}
    |> WorkflowTransition.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Insert a new workflow transition with user_id.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    %WorkflowTransition{user_id: user_id}
    |> WorkflowTransition.create_changeset(attrs)
    |> Repo.insert()
  end

  defoverridable insert: 1, insert: 2
end
