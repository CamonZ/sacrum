defmodule SacrumWeb.WorkflowTransitionJSON do
  alias Sacrum.Repo.Schemas.WorkflowTransition

  def index(%{transitions: transitions}) do
    %{data: for(t <- transitions, do: data(t))}
  end

  def show(%{transition: transition}) do
    %{data: data(transition)}
  end

  defp data(%WorkflowTransition{} = t) do
    base = %{
      id: t.id,
      from_workflow_id: t.from_workflow_id,
      to_workflow_id: t.to_workflow_id,
      target_step_id: t.target_step_id,
      label: t.label,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at
    }

    base
    |> maybe_add_workflow_name(:from_workflow_name, t, :from_workflow)
    |> maybe_add_workflow_name(:to_workflow_name, t, :to_workflow)
  end

  defp maybe_add_workflow_name(map, key, transition, assoc) do
    case Map.get(transition, assoc) do
      %{name: name} -> Map.put(map, key, name)
      _ -> map
    end
  end
end
