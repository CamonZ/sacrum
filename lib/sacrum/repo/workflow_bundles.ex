defmodule Sacrum.Repo.WorkflowBundles do
  @moduledoc """
  Atomic persistence for portable workflow bundle imports.

  The operation owns the complete workflow graph mutation. It locks the
  destination project before checking conflicts, then executes one
  `Ecto.Multi` so graph creation and final route validation either all commit
  or all roll back. Imports are additive and never change the project's
  default workflow.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Sacrum.Repo
  alias Sacrum.Repo.RouteValidation
  alias Sacrum.Repo.Schemas.{Project, StepTransition, Workflow, WorkflowStep, WorkflowTransition}
  alias Sacrum.Routing.RouteValidator
  alias Sacrum.WorkflowBundles.Manifest

  @type result :: %{
          workflows: [Workflow.t()],
          workflow_steps: [WorkflowStep.t()],
          workflow_mappings: %{String.t() => String.t()},
          step_mappings: %{String.t() => %{String.t() => String.t()}},
          id_mappings: map(),
          workflow_count: non_neg_integer(),
          step_count: non_neg_integer(),
          step_edge_count: non_neg_integer(),
          workflow_edge_count: non_neg_integer()
        }
  @type prepared :: %{
          bundle: Manifest.t(),
          workflow_ids: %{required(String.t()) => String.t()},
          step_ids: %{{String.t(), String.t()} => String.t()}
        }

  @doc "Imports a validated V1 bundle into one authenticated project."
  @spec import(String.t(), String.t(), term()) ::
          {:ok, result()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def import(user_id, project_id, bundle)
      when is_binary(user_id) and is_binary(project_id) do
    with {:ok, normalized} <- Manifest.validate(bundle),
         {:ok, prepared} <- prepare_bundle(normalized) do
      run_import(user_id, project_id, prepared)
    else
      {:error, %{path: _path, message: _message} = reason} ->
        {:error, bundle_error(reason)}
    end
  end

  @spec prepare_bundle(Manifest.t()) :: {:ok, prepared()} | {:error, Manifest.error()}
  defp prepare_bundle(bundle) do
    workflow_ids =
      Map.new(bundle.workflows, &{&1.workflow_ref, Ecto.UUID.generate()})

    step_ids =
      for workflow <- bundle.workflows, step <- workflow.steps, into: %{} do
        {{workflow.workflow_ref, step.step_ref}, Ecto.UUID.generate()}
      end

    case Manifest.remap_routes(bundle, workflow_ids, step_ids) do
      {:ok, remapped} ->
        {:ok, %{bundle: remapped, workflow_ids: workflow_ids, step_ids: step_ids}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec run_import(String.t(), String.t(), prepared()) ::
          {:ok, result()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  defp run_import(user_id, project_id, prepared) do
    multi =
      Multi.new()
      |> Multi.run(:project, fn repo, _changes -> lock_project(repo, user_id, project_id) end)
      |> Multi.run(:conflicts, fn repo, %{project: project} ->
        validate_conflicts(repo, project, prepared.bundle)
      end)
      |> add_workflow_inserts(prepared, user_id, project_id)
      |> Multi.run(:workflow_ids, fn _repo, _changes -> {:ok, prepared.workflow_ids} end)
      |> Multi.run(:step_ids, fn _repo, _changes -> {:ok, prepared.step_ids} end)
      |> add_step_inserts(prepared, user_id, project_id)
      |> add_initial_step_updates(prepared)
      |> add_step_edges(prepared, user_id, project_id)
      |> add_workflow_edges(prepared, user_id, project_id)
      |> Multi.run(:graph_validation, fn _repo, _changes ->
        validate_completed_graph(Map.values(prepared.workflow_ids))
      end)
      |> Multi.run(:result, fn _repo, changes ->
        {:ok, build_result(prepared, changes)}
      end)

    case Repo.transaction(multi) do
      {:ok, %{result: result}} ->
        {:ok, result}

      {:error, _operation, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _operation, %{path: _path, message: _message} = reason, _changes} ->
        {:error, bundle_error(reason)}

      {:error, _operation, :not_found, _changes} ->
        {:error, :not_found}

      {:error, _operation, reason, _changes} ->
        {:error, bundle_error(%{path: "$", message: inspect(reason)})}
    end
  end

  defp lock_project(repo, user_id, project_id) do
    query =
      from(project in Project,
        where: project.id == ^project_id and project.user_id == ^user_id,
        lock: "FOR UPDATE"
      )

    case repo.one(query) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :not_found}
    end
  end

  defp validate_conflicts(repo, project, bundle) do
    names = Enum.map(bundle.workflows, & &1.name)

    if length(names) != length(Enum.uniq(names)) do
      {:error, bundle_error(%{path: "workflows", message: "workflow names must be unique"})}
    else
      existing_names =
        repo.all(
          from(workflow in Workflow,
            where:
              workflow.project_id == ^project.id and workflow.user_id == ^project.user_id and
                workflow.name in ^names,
            select: workflow.name
          )
        )

      case existing_names do
        [] ->
          {:ok, :validated}

        [name | _] ->
          {:error,
           bundle_error(%{
             path: "workflows",
             message: "workflow name #{inspect(name)} already exists in the project"
           })}
      end
    end
  end

  defp add_workflow_inserts(multi, prepared, user_id, project_id) do
    Enum.reduce(prepared.bundle.workflows, multi, fn workflow, multi ->
      attrs = %{
        name: workflow.name,
        description: workflow.description,
        metadata: workflow.metadata,
        display_order: workflow.display_order,
        is_default: false,
        kanban_column: workflow.kanban_column,
        factory_name: workflow.factory_name
      }

      changeset =
        Workflow.create_changeset(
          %Workflow{
            id: Map.fetch!(prepared.workflow_ids, workflow.workflow_ref),
            project_id: project_id,
            user_id: user_id
          },
          attrs
        )

      Multi.insert(multi, {:workflow, workflow.workflow_ref}, changeset)
    end)
  end

  defp add_step_inserts(multi, prepared, user_id, project_id) do
    Enum.reduce(prepared.bundle.workflows, multi, fn workflow, multi ->
      Enum.reduce(workflow.steps, multi, fn step, multi ->
        attrs = %{
          name: step.name,
          goal: step.goal,
          agents: step.agents,
          skills: step.skills,
          agent_config: step.agent_config,
          step_order: step.step_order,
          step_type: step.step_type,
          prompt: step.prompt,
          output_schema: step.output_schema,
          persistence_options: step.persistence_options,
          route_config: step.route_config
        }

        changeset =
          WorkflowStep.create_changeset(
            %WorkflowStep{
              id: Map.fetch!(prepared.step_ids, {workflow.workflow_ref, step.step_ref}),
              workflow_id: Map.fetch!(prepared.workflow_ids, workflow.workflow_ref),
              project_id: project_id,
              user_id: user_id
            },
            attrs
          )

        Multi.insert(multi, {:step, workflow.workflow_ref, step.step_ref}, changeset)
      end)
    end)
  end

  defp add_initial_step_updates(multi, prepared) do
    Enum.reduce(prepared.bundle.workflows, multi, fn
      %{initial_step: nil}, multi ->
        multi

      workflow, multi ->
        Multi.update(multi, {:initial_step, workflow.workflow_ref}, fn changes ->
          persisted_workflow = Map.fetch!(changes, {:workflow, workflow.workflow_ref})

          step_id =
            Map.fetch!(changes.step_ids, {workflow.workflow_ref, workflow.initial_step.step_ref})

          Workflow.update_changeset(persisted_workflow, %{initial_step_id: step_id})
        end)
    end)
  end

  defp add_step_edges(multi, prepared, user_id, project_id) do
    Enum.reduce(Enum.with_index(prepared.bundle.step_edges), multi, fn {edge, index}, multi ->
      changeset =
        StepTransition.create_changeset(
          %StepTransition{user_id: user_id, project_id: project_id},
          %{
            from_step_id:
              Map.fetch!(prepared.step_ids, {edge.from.workflow_ref, edge.from.step_ref}),
            to_step_id: Map.fetch!(prepared.step_ids, {edge.to.workflow_ref, edge.to.step_ref}),
            label: edge.label
          }
        )

      Multi.insert(multi, {:step_edge, index}, changeset)
    end)
  end

  defp add_workflow_edges(multi, prepared, user_id, project_id) do
    Enum.reduce(Enum.with_index(prepared.bundle.workflow_edges), multi, fn {edge, index}, multi ->
      Multi.insert(multi, {:workflow_edge, index}, fn _changes ->
        WorkflowTransition.create_changeset(
          %WorkflowTransition{user_id: user_id, project_id: project_id},
          workflow_edge_attrs(edge, prepared)
        )
      end)
    end)
  end

  defp workflow_edge_attrs(edge, prepared) do
    target_step_id =
      case edge.destination_step do
        nil ->
          nil

        destination ->
          Map.fetch!(prepared.step_ids, {destination.workflow_ref, destination.step_ref})
      end

    %{
      from_workflow_id: Map.fetch!(prepared.workflow_ids, edge.from_workflow_ref),
      to_workflow_id: Map.fetch!(prepared.workflow_ids, edge.to_workflow_ref),
      target_step_id: target_step_id,
      label: edge.label
    }
  end

  defp validate_completed_graph([]), do: {:ok, :validated}

  defp validate_completed_graph(workflow_ids) do
    workflow_ids
    |> Enum.reduce_while(:ok, fn workflow_id, :ok ->
      with {:ok, snapshot} <- RouteValidation.load_snapshot(workflow_id),
           :ok <- RouteValidator.validate_snapshot(snapshot, [workflow_id]) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:ok, :validated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_result(prepared, changes) do
    workflows =
      Enum.map(prepared.bundle.workflows, fn workflow ->
        operation =
          if workflow.initial_step,
            do: {:initial_step, workflow.workflow_ref},
            else: {:workflow, workflow.workflow_ref}

        Map.fetch!(changes, operation)
      end)

    workflow_steps =
      for workflow <- prepared.bundle.workflows, step <- workflow.steps do
        Map.fetch!(changes, {:step, workflow.workflow_ref, step.step_ref})
      end

    step_mappings =
      Enum.reduce(prepared.bundle.workflows, %{}, fn workflow, acc ->
        steps =
          Map.new(workflow.steps, fn step ->
            {step.step_ref, Map.fetch!(prepared.step_ids, {workflow.workflow_ref, step.step_ref})}
          end)

        Map.put(acc, workflow.workflow_ref, steps)
      end)

    %{
      workflows: workflows,
      workflow_steps: workflow_steps,
      workflow_mappings: prepared.workflow_ids,
      step_mappings: step_mappings,
      id_mappings: %{workflows: prepared.workflow_ids, steps: step_mappings},
      workflow_count: length(workflows),
      step_count: length(workflow_steps),
      step_edge_count: length(prepared.bundle.step_edges),
      workflow_edge_count: length(prepared.bundle.workflow_edges)
    }
  end

  defp bundle_error(%{path: path, message: message}) do
    Ecto.Changeset.add_error(Ecto.Changeset.change(%Workflow{}), :bundle, "#{path}: #{message}")
  end
end
