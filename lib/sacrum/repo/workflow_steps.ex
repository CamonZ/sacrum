defmodule Sacrum.Repo.WorkflowSteps do
  @moduledoc """
  CRUD operations for workflow steps.

  ## Error Contract

  - `get/1` returns `{:ok, step}` or `{:error, :not_found}`
  - `get!/1` returns step or raises
  - `get_by/1` returns `{:ok, step}` or `{:error, :not_found}`
  - `all/0` returns `[step]`
  - `insert/1` returns `{:ok, step}` or `{:error, changeset}`
  - `update/1` returns `{:ok, step}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, step}` or `{:error, changeset}`
  - `sync_transitions/2` returns `{:ok, [transitions]}` or `{:error, changeset}` or `{:error, atom}`

  ## Domain-Specific Errors

  `sync_transitions/2` may return `{:error, atom}` for:
  - `:duplicate_to_step_ids` - when transition list has duplicate target steps
  - `:different_workflows` - when target steps belong to different workflows
  - `:finish_step_cannot_have_outgoing_transition` - when the step is a finish step and transitions are supplied
  - `:stop_step_requires_exactly_one_outgoing_transition` - when a stop step does not have exactly one transition

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.WorkflowStep

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.SyncHelper
  alias Sacrum.Repo.UuidPrefixResolver

  @spec find_by_uuid_prefix(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, WorkflowStep.t()}
          | {:error, :not_found | :invalid_prefix}
          | {:error, {:ambiguous, [String.t()]}}
  def find_by_uuid_prefix(prefix, project_id, workflow_id, user_id) do
    query =
      from(s in WorkflowStep,
        where:
          s.workflow_id == ^workflow_id and
            s.project_id == ^project_id and
            s.user_id == ^user_id
      )

    UuidPrefixResolver.find_by_prefix(query, prefix)
  end

  @doc """
  Insert a new workflow step. Accepts Workflow struct (with or without user_id).
  """
  @spec insert(Workflow.t(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  @spec insert(String.t(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Workflow{} = workflow, attrs) when is_map(attrs),
    do: insert_step(workflow, attrs)

  def insert(workflow_id, attrs) when is_binary(workflow_id) and is_map(attrs),
    do: insert_step(%Workflow{id: workflow_id}, attrs)

  defoverridable insert: 2

  @spec insert(String.t(), String.t(), map()) ::
          {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def insert(workflow_id, user_id, attrs)
      when is_binary(workflow_id) and is_binary(user_id) and is_map(attrs) do
    insert_step(%Workflow{id: workflow_id, user_id: user_id}, attrs)
  end

  @spec insert(String.t(), String.t(), String.t(), map()) ::
          {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def insert(workflow_id, project_id, user_id, attrs)
      when is_binary(workflow_id) and is_binary(project_id) and is_binary(user_id) do
    insert_step(
      %Workflow{id: workflow_id, project_id: project_id, user_id: user_id},
      attrs
    )
  end

  @spec update(WorkflowStep.t(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def update(%WorkflowStep{} = step, attrs) do
    Repo.transaction(fn ->
      workflow = lock_workflow(step.workflow_id)

      case lock_step(step) do
        nil -> Repo.rollback(missing_step_changeset(step, attrs))
        current_step -> update_locked_step(workflow, current_step, attrs)
      end
    end)
  end

  @doc """
  Syncs outgoing transitions for a step. Accepts a list of maps with
  `to_step_id` and optional `label`. Diffs against existing StepTransition
  records where from_step_id matches, adding new ones and removing absent ones.

  Returns `{:ok, [%StepTransition{}]}` or `{:error, reason}`.
  """
  @spec sync_transitions(WorkflowStep.t(), list()) ::
          {:ok, list()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def sync_transitions(%WorkflowStep{} = step, transitions) when is_list(transitions) do
    step = Repo.preload(step, :workflow)

    with :ok <- validate_finish_step(step, transitions),
         :ok <- validate_stop_step(step, transitions),
         :ok <- validate_no_duplicate_targets(transitions),
         :ok <- validate_same_workflow(step, transitions) do
      existing =
        Repo.all(from(t in StepTransition, where: t.from_step_id == ^step.id))

      SyncHelper.diff_and_sync(existing, transitions, %{
        target_key: :to_step_id,
        to_delete_fn: fn existing, incoming_target_ids ->
          Enum.filter(existing, fn t -> not MapSet.member?(incoming_target_ids, t.to_step_id) end)
        end,
        to_insert_fn: fn incoming, existing_by_target ->
          Enum.filter(incoming, fn t ->
            to_id = to_step_id(t)
            not Map.has_key?(existing_by_target, to_id)
          end)
        end,
        to_update_fn: fn _incoming, _existing_by_target ->
          # No updates for step transitions - they're created with just from/to, no other mutable fields
          []
        end,
        build_changeset_fn: fn t ->
          to_id = to_step_id(t)

          StepTransition.create_changeset(
            %StepTransition{user_id: step.user_id, project_id: step.project_id},
            %{
              from_step_id: step.id,
              to_step_id: to_id,
              label: label_for(t)
            }
          )
        end,
        build_update_changeset_fn: fn _existing, _map ->
          # No-op for step transitions
          nil
        end,
        fetch_final_fn: fn ->
          updated =
            Repo.all(
              from(t in StepTransition,
                where: t.from_step_id == ^step.id,
                order_by: [asc: t.inserted_at]
              )
            )

          {:ok, updated}
        end
      })
    end
  end

  # sync_transitions helpers

  defp validate_finish_step(%WorkflowStep{step_type: :finish}, [_ | _]),
    do: {:error, :finish_step_cannot_have_outgoing_transition}

  defp validate_finish_step(_step, _transitions), do: :ok

  defp validate_stop_step(%WorkflowStep{step_type: :stop}, [_]), do: :ok

  defp validate_stop_step(%WorkflowStep{step_type: :stop}, _transitions),
    do: {:error, :stop_step_requires_exactly_one_outgoing_transition}

  defp validate_stop_step(_step, _transitions), do: :ok

  defp to_step_id(%{"to_step_id" => id}), do: id
  defp to_step_id(%{to_step_id: id}), do: id

  defp label_for(%{"label" => label}), do: label
  defp label_for(%{label: label}), do: label
  defp label_for(_), do: nil

  defp validate_no_duplicate_targets(transitions) do
    ids = Enum.map(transitions, &to_step_id/1)

    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, :duplicate_to_step_ids}
    end
  end

  defp validate_same_workflow(%WorkflowStep{workflow_id: wf_id}, transitions) do
    to_ids = Enum.map(transitions, &to_step_id/1)

    if to_ids == [] do
      :ok
    else
      count =
        Repo.aggregate(
          from(s in WorkflowStep,
            where: s.id in ^to_ids and s.workflow_id == ^wf_id
          ),
          :count
        )

      if count == length(to_ids) do
        :ok
      else
        {:error, :different_workflows}
      end
    end
  end

  @spec delete(WorkflowStep.t()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def delete(%WorkflowStep{} = step) do
    Repo.transaction(fn ->
      workflow = lock_workflow(step.workflow_id)

      case lock_step(step) do
        nil -> Repo.rollback(missing_step_changeset(step, %{}))
        current_step -> delete_locked_step(workflow, current_step)
      end
    end)
  end

  # Ordering and pointer changes share the workflow row lock. This keeps the
  # sibling list and initial pointer consistent for concurrent mutations.

  defp insert_step(%Workflow{id: workflow_id} = input_workflow, attrs) do
    Repo.transaction(fn ->
      workflow = lock_workflow(workflow_id) || input_workflow

      step = %WorkflowStep{
        workflow_id: workflow.id,
        project_id: workflow.project_id,
        user_id: workflow.user_id
      }

      with :ok <- validate_initial_step(workflow, step),
           changeset <- WorkflowStep.create_changeset(step, attrs),
           :ok <- ensure_valid(changeset),
           siblings <- workflow_steps(workflow.id),
           {:ok, inserted_step} <- insert_ordered_step(siblings, changeset),
           :ok <- maybe_set_initial_step(workflow, inserted_step, siblings) do
        inserted_step
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_locked_step(workflow, current_step, attrs) do
    with :ok <- validate_initial_step(workflow, current_step),
         changeset <- WorkflowStep.update_changeset(current_step, preserve_order(attrs)),
         :ok <- ensure_valid(changeset) do
      if order_supplied?(attrs) do
        reorder_and_update(workflow, current_step, changeset)
      else
        update_step(changeset)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp delete_locked_step(workflow, current_step) do
    with :ok <- validate_initial_step(workflow, current_step),
         siblings <- workflow_steps(workflow.id, current_step.id),
         {:ok, deleted_step} <- Repo.delete(current_step),
         :ok <- renumber_steps(siblings),
         :ok <- reconcile_initial_step(workflow, current_step.id, siblings) do
      deleted_step
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_ordered_step(siblings, changeset) do
    count = length(siblings)
    requested_order = Ecto.Changeset.get_field(changeset, :step_order)

    case insertion_position(requested_order, count) do
      {:ok, position} ->
        renumber_for_insert(siblings, position)

        changeset = Ecto.Changeset.put_change(changeset, :step_order, position)

        case Repo.insert(changeset) do
          {:ok, step} -> {:ok, step}
          {:error, changeset} -> {:error, changeset}
        end

      {:error, message} ->
        {:error, Ecto.Changeset.add_error(changeset, :step_order, message)}
    end
  end

  defp reorder_and_update(workflow, current_step, changeset) do
    steps = workflow_steps(workflow.id)
    current_index = Enum.find_index(steps, &(&1.id == current_step.id))
    requested_order = Ecto.Changeset.get_field(changeset, :step_order)

    cond do
      is_nil(current_index) ->
        Repo.rollback(Ecto.Changeset.add_error(changeset, :id, "does not belong to its workflow"))

      not valid_move_position?(requested_order, length(steps)) ->
        Repo.rollback(
          Ecto.Changeset.add_error(
            changeset,
            :step_order,
            "must be between 0 and #{max(length(steps) - 1, 0)}"
          )
        )

      requested_order == current_index ->
        update_step(changeset)

      true ->
        steps
        |> List.delete_at(current_index)
        |> List.insert_at(requested_order, current_step)
        |> renumber_steps(current_step.id)

        update_step(changeset)
    end
  end

  defp update_step(changeset) do
    case Repo.update(changeset) do
      {:ok, step} -> step
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp validate_initial_step(%Workflow{initial_step_id: nil}, _step), do: :ok

  defp validate_initial_step(%Workflow{} = workflow, step) do
    query =
      from(s in WorkflowStep,
        where:
          s.id == ^workflow.initial_step_id and
            s.workflow_id == ^workflow.id and
            s.project_id == ^workflow.project_id and
            s.user_id == ^workflow.user_id,
        select: s.id
      )

    if Repo.exists?(query) do
      :ok
    else
      {:error,
       Ecto.Changeset.add_error(
         WorkflowStep.update_changeset(step, %{}),
         :workflow_id,
         "workflow has an invalid initial_step_id"
       )}
    end
  end

  defp maybe_set_initial_step(%Workflow{initial_step_id: nil} = workflow, step, []) do
    case Repo.update(Ecto.Changeset.change(workflow, initial_step_id: step.id)) do
      {:ok, _workflow} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_set_initial_step(_workflow, _step, _siblings), do: :ok

  defp reconcile_initial_step(
         %Workflow{initial_step_id: initial_step_id} = workflow,
         deleted_step_id,
         siblings
       ) do
    if initial_step_id == deleted_step_id do
      next_initial_step_id =
        case siblings do
          [step | _] -> step.id
          [] -> nil
        end

      case Repo.update(Ecto.Changeset.change(workflow, initial_step_id: next_initial_step_id)) do
        {:ok, _workflow} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    else
      :ok
    end
  end

  defp lock_workflow(workflow_id) do
    Repo.one(from(w in Workflow, where: w.id == ^workflow_id, lock: "FOR UPDATE"))
  end

  defp lock_step(%WorkflowStep{workflow_id: workflow_id, id: step_id}) do
    Repo.one(from(s in WorkflowStep, where: s.id == ^step_id and s.workflow_id == ^workflow_id))
  end

  defp workflow_steps(workflow_id, excluded_step_id \\ nil) do
    query =
      from(s in WorkflowStep,
        where: s.workflow_id == ^workflow_id,
        order_by: [asc_nulls_last: s.step_order, asc: s.inserted_at, asc: s.id]
      )

    query =
      if excluded_step_id, do: from(s in query, where: s.id != ^excluded_step_id), else: query

    Repo.all(query)
  end

  defp renumber_for_insert(siblings, position) do
    siblings
    |> Enum.with_index()
    |> Enum.each(fn {step, index} ->
      update_step_order(step, if(index < position, do: index, else: index + 1))
    end)
  end

  defp renumber_steps(steps, current_step_id \\ nil) do
    steps
    |> Enum.with_index()
    |> Enum.each(fn {step, index} ->
      if step.id != current_step_id, do: update_step_order(step, index)
    end)

    :ok
  end

  defp update_step_order(%WorkflowStep{step_order: current_order}, current_order), do: :ok

  defp update_step_order(%WorkflowStep{id: step_id}, target_order) do
    Repo.update_all(
      from(s in WorkflowStep, where: s.id == ^step_id),
      set: [step_order: target_order, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  defp insertion_position(nil, count), do: {:ok, count}

  defp insertion_position(order, count) when is_integer(order) and order >= 0 do
    cond do
      order <= count -> {:ok, order}
      order == count + 1 -> {:ok, count}
      true -> {:error, "must be between 0 and #{count}"}
    end
  end

  defp insertion_position(_order, count), do: {:error, "must be between 0 and #{count}"}

  defp valid_move_position?(order, count) when is_integer(order), do: order >= 0 and order < count
  defp valid_move_position?(_order, _count), do: false

  defp order_supplied?(attrs),
    do: Map.has_key?(attrs, :step_order) or Map.has_key?(attrs, "step_order")

  defp preserve_order(attrs) do
    cond do
      Map.get(attrs, :step_order, :missing) == nil -> Map.delete(attrs, :step_order)
      Map.get(attrs, "step_order", :missing) == nil -> Map.delete(attrs, "step_order")
      true -> attrs
    end
  end

  defp ensure_valid(%Ecto.Changeset{valid?: true}), do: :ok
  defp ensure_valid(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  defp missing_step_changeset(step, attrs) do
    step
    |> WorkflowStep.update_changeset(attrs)
    |> Ecto.Changeset.add_error(:id, "does not exist")
  end

  @doc """
  Diagnostic-only setter that bypasses the public @update_fields allowlist.
  Intended for iex / direct DB toggling — not exposed via GraphQL.
  """
  @spec set_verbose_logging(WorkflowStep.t(), boolean()) ::
          {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def set_verbose_logging(%WorkflowStep{} = step, enabled) when is_boolean(enabled) do
    step
    |> Ecto.Changeset.change(verbose_daemon_logging: enabled)
    |> Repo.update()
  end
end
