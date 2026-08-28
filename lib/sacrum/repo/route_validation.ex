defmodule Sacrum.Repo.RouteValidation do
  @moduledoc """
  Persistence boundary for graph-aware route validation.

  - `load_snapshot/1` loads the affected-workflow component (steps, step
    edges, workflow edges) that route validation reads. The Orchestrator uses
    the same loader, so persist-time revalidation and runtime snapshots agree.
  - `mutate/3` is the single authoring save path: resolve and lock the
    connected component's workflow rows (`FOR UPDATE`, acquired in id order),
    apply the write, reload the component inside the transaction, and
    revalidate every configured route against it. Rollback restores the
    pre-mutation graph.

  The pure validation semantics live in `Sacrum.Routing.RouteValidator`.
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepTransition, Workflow, WorkflowStep, WorkflowTransition}
  alias Sacrum.Routing.RouteValidator

  @type snapshot :: RouteValidator.snapshot()

  @doc """
  Loads a validation snapshot for the workflows connected to `workflow_id`.

  The component is the workflow itself, every workflow directly reachable
  from it, and every workflow that can reach it — the set whose configured
  routes a mutation on this workflow can invalidate.
  """
  @spec load_snapshot(binary()) :: {:ok, snapshot()} | {:error, :workflow_not_found}
  def load_snapshot(workflow_id) do
    component_ids = connected_workflows([workflow_id])

    if component_ids == [] do
      {:error, :workflow_not_found}
    else
      {:ok, build_snapshot(component_ids)}
    end
  end

  @doc """
  The single authoring save path for graph mutations.

  `affected_workflow_ids` lists the workflows whose routes this mutation can
  affect. The connected component is resolved and its workflow rows locked
  **before** the write — for deletes, the anchor workflow and its edges
  disappear with the row, so post-write resolution would silently skip
  validation. The component is reloaded inside the transaction after the
  write and every configured route is revalidated against it. Callers never
  compute before/after route-id sets; insert and delete timings are handled
  by construction.
  """
  @spec mutate([binary()], Ecto.Changeset.t() | struct(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, Ecto.Changeset.t() | term()}
  def mutate(affected_workflow_ids, original, mutation_fn) do
    affected = affected_workflow_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    result =
      Repo.transaction(fn ->
        component_ids = connected_workflows(affected)
        lock_workflows(component_ids)

        case mutation_fn.() do
          {:ok, result} -> revalidate_component(component_ids, result)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    normalize(result, original)
  end

  #
  # Component resolution and snapshot construction
  #

  defp connected_workflows(seed_ids) do
    ids = seed_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    edges =
      Repo.all(
        from(t in WorkflowTransition,
          where: t.from_workflow_id in ^ids or t.to_workflow_id in ^ids,
          select: {t.from_workflow_id, t.to_workflow_id}
        )
      )

    neighbor_ids = edges |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    (ids ++ neighbor_ids)
    |> Enum.uniq()
    |> Enum.filter(&workflow_exists?/1)
  end

  defp workflow_exists?(workflow_id) do
    Repo.exists?(from(w in Workflow, where: w.id == ^workflow_id))
  end

  defp build_snapshot(component_ids) do
    steps =
      Repo.all(
        from(step in WorkflowStep,
          where: step.workflow_id in ^component_ids,
          order_by: [asc: step.inserted_at, asc: step.id]
        )
      )

    steps_by_id = Map.new(steps, &{&1.id, &1})

    raw_step_edges =
      Repo.all(
        from(t in StepTransition,
          join: source in WorkflowStep,
          on: source.id == t.from_step_id,
          where: source.workflow_id in ^component_ids,
          select: %{id: t.id, from_step_id: t.from_step_id, to_step_id: t.to_step_id}
        )
      )

    step_edges =
      Enum.group_by(raw_step_edges, & &1.from_step_id, fn edge ->
        %{transition_id: edge.id, to_step_id: edge.to_step_id}
      end)

    raw_workflow_edges =
      Repo.all(
        from(t in WorkflowTransition,
          join: destination in Workflow,
          on: destination.id == t.to_workflow_id,
          where: t.from_workflow_id in ^component_ids,
          select: %{
            from_workflow_id: t.from_workflow_id,
            to_workflow_id: t.to_workflow_id,
            target_step_id: t.target_step_id,
            initial_step_id: destination.initial_step_id
          }
        )
      )

    workflow_edges =
      Map.new(raw_workflow_edges, fn edge ->
        {{edge.from_workflow_id, edge.to_workflow_id},
         %{
           target_step_id: edge.target_step_id,
           destination_workflow_id: edge.to_workflow_id,
           initial_step_id: edge.initial_step_id
         }}
      end)

    %{steps: steps_by_id, step_edges: step_edges, workflow_edges: workflow_edges}
  end

  #
  # Revalidation, locking, and error translation
  #

  defp revalidate_component(component_ids, result) do
    case component_ids do
      [] ->
        result

      ids ->
        case RouteValidator.validate_snapshot(build_snapshot(ids)) do
          :ok -> result
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  # Locks are acquired in id order so concurrent mutations touching
  # overlapping components serialize deterministically and cannot deadlock.
  defp lock_workflows(ids) do
    ids
    |> Enum.sort()
    |> Enum.each(fn id ->
      Repo.one(from(w in Workflow, where: w.id == ^id, lock: "FOR UPDATE"))
    end)
  end

  defp normalize({:ok, result}, _original), do: {:ok, result}

  defp normalize({:error, %Ecto.Changeset{} = changeset}, _original), do: {:error, changeset}

  defp normalize({:error, %{code: _code} = reason}, original),
    do: {:error, error_changeset(original, reason)}

  defp normalize({:error, reason}, _original), do: {:error, reason}

  @doc """
  Converts a route-validation error into a changeset error for the mutation
  caller while preserving its stable, path-aware explanation.

  The diagnostic always lands on `:route_config`: it names the configured
  route step whose configuration is now invalid, wherever the mutation that
  broke it happened to originate.
  """
  @spec error_changeset(Ecto.Changeset.t() | struct(), RouteValidator.error()) ::
          Ecto.Changeset.t()
  def error_changeset(%Ecto.Changeset{} = changeset, reason) do
    Ecto.Changeset.add_error(changeset, :route_config, error_message(reason))
  end

  def error_changeset(record, reason) do
    record
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:route_config, error_message(reason))
  end

  defp error_message(%{path: path, message: message}), do: "#{path}: #{message}"
end
