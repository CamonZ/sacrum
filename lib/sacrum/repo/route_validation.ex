defmodule Sacrum.Repo.RouteValidation do
  @moduledoc """
  Persistence boundary for graph-aware route validation.

  A mutation or runtime load names the **owner** workflows whose routes must
  be proved. The snapshot is the **support** graph those routes read: the
  owners plus their outgoing destinations. Destination steps are data, not
  additional routes to validate.

  - `load_snapshot/1` loads support for the given owner workflow.
  - `mutate/3` locks the pre-write support rows (`FOR UPDATE`, id order),
    applies the write, reloads support for the still-existing owners, and
    revalidates only those owners' routes.

  The pure validation semantics live in `Sacrum.Routing.RouteValidator`.
  """

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepTransition, Workflow, WorkflowStep, WorkflowTransition}
  alias Sacrum.Routing.RouteValidator

  @type snapshot :: RouteValidator.snapshot()

  @doc """
  Loads the support snapshot for proving `workflow_id`'s routes.

  Support is that workflow plus every workflow it can reach in one
  workflow-transition hop — the destinations its configured routes read.
  Incoming neighbors are not owners at runtime and are not loaded here.
  """
  @spec load_snapshot(binary()) :: {:ok, snapshot()} | {:error, :workflow_not_found}
  def load_snapshot(workflow_id) when is_binary(workflow_id) do
    case existing_workflow_ids([workflow_id]) do
      [] ->
        {:error, :workflow_not_found}

      owners ->
        {:ok, build_snapshot(support_ids(owners))}
    end
  end

  @doc """
  The single authoring save path for graph mutations.

  `affected_workflow_ids` is the seed: workflows whose rows this mutation
  touches. Owners are that seed plus incoming neighbors — the routes a
  mutation here can invalidate. Support is owners plus their outgoing
  destinations. Owners and support are resolved **before** the write so a
  delete cannot drop the rows we need to lock; after the write, remaining
  owners are revalidated against the post-write support graph.
  """
  @spec mutate([binary()], Ecto.Changeset.t() | struct(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, Ecto.Changeset.t() | term()}
  def mutate(affected_workflow_ids, original, mutation_fn) do
    affected = affected_workflow_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    result =
      Repo.transaction(fn ->
        graph = resolve_graph(affected)
        lock_workflows(graph.support)

        case mutation_fn.() do
          {:ok, result} -> revalidate_owners(graph.owners, result)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    normalize(result, original)
  end

  #
  # Owner / support resolution and snapshot construction
  #

  defp resolve_graph(seed_ids) do
    seed = existing_workflow_ids(seed_ids)
    owners = Enum.uniq(seed ++ incoming_ids(seed))
    %{owners: owners, support: support_ids(owners)}
  end

  defp support_ids(owners), do: Enum.uniq(owners ++ outgoing_ids(owners))

  defp existing_workflow_ids(ids) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    case ids do
      [] -> []
      ids -> Repo.all(from(w in Workflow, where: w.id in ^ids, select: w.id))
    end
  end

  defp incoming_ids([]), do: []

  defp incoming_ids(ids) do
    Repo.all(
      from(t in WorkflowTransition,
        where: t.to_workflow_id in ^ids,
        select: t.from_workflow_id
      )
    )
  end

  defp outgoing_ids([]), do: []

  defp outgoing_ids(ids) do
    Repo.all(
      from(t in WorkflowTransition,
        where: t.from_workflow_id in ^ids,
        select: t.to_workflow_id
      )
    )
  end

  defp build_snapshot(support_ids) do
    steps =
      Repo.all(
        from(step in WorkflowStep,
          where: step.workflow_id in ^support_ids,
          order_by: [asc: step.inserted_at, asc: step.id]
        )
      )

    steps_by_id = Map.new(steps, &{&1.id, &1})

    raw_step_edges =
      Repo.all(
        from(t in StepTransition,
          join: source in WorkflowStep,
          on: source.id == t.from_step_id,
          where: source.workflow_id in ^support_ids,
          select: %{id: t.id, from_step_id: t.from_step_id, to_step_id: t.to_step_id}
        )
      )

    step_edges =
      Enum.group_by(raw_step_edges, & &1.from_step_id, fn edge ->
        step_edge(edge)
      end)

    incoming_edges =
      Enum.group_by(raw_step_edges, & &1.to_step_id, fn edge ->
        step_edge(edge)
      end)

    raw_workflow_edges =
      Repo.all(
        from(t in WorkflowTransition,
          join: destination in Workflow,
          on: destination.id == t.to_workflow_id,
          where: t.from_workflow_id in ^support_ids,
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

    %{
      steps: steps_by_id,
      step_edges: step_edges,
      incoming_edges: incoming_edges,
      workflow_edges: workflow_edges
    }
  end

  defp step_edge(edge) do
    %{transition_id: edge.id, from_step_id: edge.from_step_id, to_step_id: edge.to_step_id}
  end

  #
  # Revalidation, locking, and error translation
  #

  defp revalidate_owners(owners, result) do
    case existing_workflow_ids(owners) do
      [] ->
        result

      remaining ->
        snapshot = build_snapshot(support_ids(remaining))

        case RouteValidator.validate_snapshot(snapshot, remaining) do
          :ok -> result
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  # Locks are acquired in id order so concurrent mutations touching
  # overlapping support sets serialize deterministically and cannot deadlock.
  defp lock_workflows([]), do: :ok

  defp lock_workflows(ids) do
    sorted = ids |> Enum.uniq() |> Enum.sort()

    Repo.all(
      from(w in Workflow,
        where: w.id in ^sorted,
        order_by: [asc: w.id],
        lock: "FOR UPDATE"
      )
    )

    :ok
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
