defmodule Sacrum.Repo.StepTransitions do
  @moduledoc """
  CRUD operations for step transitions within a workflow.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Schemas.WorkflowStep

  def get(id) do
    case Repo.get(StepTransition, id) do
      nil -> {:error, :not_found}
      transition -> {:ok, transition}
    end
  end

  def list_for_step(%WorkflowStep{id: step_id}), do: list_for_step(step_id)

  def list_for_step(from_step_id) when is_binary(from_step_id) do
    from(t in StepTransition,
      where: t.from_step_id == ^from_step_id,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  def insert(attrs) do
    with :ok <- validate_same_workflow(attrs) do
      %StepTransition{}
      |> StepTransition.create_changeset(attrs)
      |> Repo.insert()
      |> broadcast(:step_transition_created)
    end
  end

  def delete(%StepTransition{} = transition) do
    case Repo.delete(transition) do
      {:ok, deleted} ->
        broadcast_event(deleted, :step_transition_deleted)
        {:ok, deleted}

      error ->
        error
    end
  end

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

          from_step.workflow_id != to_step.workflow_id ->
            {:error, :different_workflows}

          true ->
            :ok
        end
    end
  end

  defp broadcast({:ok, transition}, event) do
    broadcast_event(transition, event)
    {:ok, transition}
  end

  defp broadcast({:error, _} = error, _event), do: error

  defp broadcast_event(transition, event) do
    transition = Repo.preload(transition, from_step: [workflow: :project])

    case transition do
      %{from_step: %{workflow: %{project: %{slug: slug}}}} ->
        apply(SacrumWeb.ProjectChannel, :"broadcast_#{event}", [slug, transition])

      _ ->
        :ok
    end
  end
end
