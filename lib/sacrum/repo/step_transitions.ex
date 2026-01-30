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

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.StepTransition

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Schemas.WorkflowStep

  def list_for_step(%WorkflowStep{id: step_id}), do: list_for_step(step_id)

  def list_for_step(from_step_id) when is_binary(from_step_id) do
    from(t in StepTransition,
      where: t.from_step_id == ^from_step_id,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  def list_for_step(from_step_id, user_id) when is_binary(from_step_id) and is_binary(user_id) do
    from(t in StepTransition,
      where: t.from_step_id == ^from_step_id and t.user_id == ^user_id,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Insert a new step transition from attrs map.
  """
  def insert(attrs) when is_map(attrs) do
    with :ok <- validate_same_workflow(attrs) do
      %StepTransition{}
      |> StepTransition.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Insert a new step transition with user_id.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    with :ok <- validate_same_workflow(attrs) do
      %StepTransition{user_id: user_id}
      |> StepTransition.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  defoverridable insert: 1, insert: 2

  defp validate_same_workflow(attrs) do
    from_id = attrs[:from_step_id] || attrs["from_step_id"]
    to_id = attrs[:to_step_id] || attrs["to_step_id"]

    case {from_id, to_id} do
      {nil, _} ->
        :ok

      {_, nil} ->
        :ok

      {from_id, to_id} ->
        from_step = Repo.get(WorkflowStep, from_id)
        to_step = Repo.get(WorkflowStep, to_id)

        cond do
          is_nil(from_step) or is_nil(to_step) ->
            :ok

          from_step.workflow_id == to_step.workflow_id ->
            :ok

          true ->
            {:error, :different_workflows}
        end
    end
  end
end
