defmodule Sacrum.Import do
  @moduledoc """
  Imports data from the embedded_db_dump JSON files into the PostgreSQL database.

  Reads JSON files from a data directory and creates all resources with new UUIDs,
  maintaining an ID mapping throughout so that relationships between entities are
  preserved correctly.

  ## Usage

      # Requires a project and user to own the imported data
      Sacrum.Import.run(project, user, "/path/to/data/directory")

  ## Import Order

  1. Workflows
  2. Workflow steps (+ step transitions)
  3. Workflow initial_step_id backfill
  4. Workflow transitions
  5. Tasks (with sections and code refs)
  6. Task hierarchy (parent/child)
  7. Task dependencies
  8. Step executions
  """

  require Logger

  alias Ecto.Changeset
  alias Sacrum.Repo

  alias Sacrum.Repo.Schemas.{
    Workflow,
    WorkflowStep,
    StepTransition,
    WorkflowTransition,
    Task,
    CodeRef,
    TaskHierarchy,
    TaskDependency,
    StepExecution
  }

  # --- Public types ---

  @typedoc "Maps old string IDs from the dump to new UUID strings."
  @type id_map :: %{String.t() => Ecto.UUID.t()}

  @typedoc "Decoded JSON object (string keys)."
  @type json_map :: %{String.t() => term()}

  @typedoc "An Ecto schema struct with at least an :id field."
  @type project :: %{:id => Ecto.UUID.t(), :user_id => Ecto.UUID.t(), optional(atom()) => term()}
  @type user :: %{:id => Ecto.UUID.t(), optional(atom()) => term()}

  @typedoc "Summary of all imported record counts plus the ID mappings."
  @type import_summary :: %{
          workflows: non_neg_integer(),
          workflow_steps: non_neg_integer(),
          step_transitions: non_neg_integer(),
          workflow_transitions: non_neg_integer(),
          tasks: non_neg_integer(),
          sections: non_neg_integer(),
          code_refs: non_neg_integer(),
          hierarchy: non_neg_integer(),
          dependencies: non_neg_integer(),
          step_executions: non_neg_integer(),
          id_maps: %{
            workflows: id_map(),
            steps: id_map(),
            tasks: id_map()
          }
        }

  @typedoc "The loaded JSON data from all files."
  @type loaded_data :: %{
          workflows: [json_map()],
          tasks: [json_map()],
          relationships: json_map(),
          workflow_transitions: [json_map()],
          step_executions: [json_map()]
        }

  @typedoc "Import error reasons."
  @type import_error ::
          {:file_read, atom(), File.posix()}
          | {:json_decode, atom(), Jason.DecodeError.t()}
          | {:workflow, term(), Changeset.t()}
          | {:workflow_step, term(), Changeset.t()}
          | {:step_transition, String.t(), String.t(), Changeset.t()}
          | {:backfill_initial_step, String.t(), Changeset.t()}
          | {:workflow_transition, String.t(), String.t(), Changeset.t()}
          | {:task, term(), Changeset.t()}
          | {:code_ref, Ecto.UUID.t(), Changeset.t()}
          | {:hierarchy, String.t(), String.t(), Changeset.t()}
          | {:dependency, String.t(), String.t(), Changeset.t()}
          | {:step_execution, term(), Changeset.t()}

  @type result :: {:ok, import_summary()} | {:error, import_error()}

  # --- Public API ---

  @doc """
  Runs the full import from JSON files in `data_dir`.

  `project` must be a `%Project{}` struct with an `id` and `user_id`.
  `user` must be a `%User{}` struct with an `id`.
  """
  @spec run(project(), user(), String.t()) :: result()
  def run(project, user, data_dir) do
    with {:ok, data} <- load_files(data_dir) do
      do_import(project, user, data)
    end
  end

  # --- File loading ---

  @spec load_files(String.t()) :: {:ok, loaded_data()} | {:error, import_error()}
  defp load_files(data_dir) do
    files = %{
      workflows: Path.join(data_dir, "workflows.json"),
      tasks: Path.join(data_dir, "tasks.json"),
      relationships: Path.join(data_dir, "relationships.json"),
      workflow_transitions: Path.join(data_dir, "workflow_transitions.json"),
      step_executions: Path.join(data_dir, "step_executions.json")
    }

    Enum.reduce_while(files, {:ok, %{}}, fn {key, path}, {:ok, acc} ->
      case File.read(path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, data} -> {:cont, {:ok, Map.put(acc, key, data)}}
            {:error, reason} -> {:halt, {:error, {:json_decode, key, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:file_read, key, reason}}}
      end
    end)
  end

  # --- Orchestration ---

  @spec do_import(project(), user(), loaded_data()) :: result()
  defp do_import(project, user, data) do
    Repo.transaction(fn ->
      with {:ok, workflow_map, wf_count} <-
             import_workflows(project, user, data.workflows),
           {:ok, step_map, step_count, st_count} <-
             import_workflow_steps(user, workflow_map, data.workflows),
           {:ok, _} <-
             backfill_initial_step_ids(workflow_map, step_map, data.workflows),
           {:ok, wt_count} <-
             import_workflow_transitions(user, workflow_map, step_map, data.workflow_transitions),
           {:ok, task_map, task_count, sec_count, ref_count} <-
             import_tasks(project, user, workflow_map, step_map, data.tasks),
           {:ok, hier_count} <-
             import_hierarchy(user, task_map, data.relationships),
           {:ok, dep_count} <-
             import_dependencies(user, task_map, data.relationships),
           {:ok, se_count} <-
             import_step_executions(user, workflow_map, task_map, data.step_executions) do
        %{
          workflows: wf_count,
          workflow_steps: step_count,
          step_transitions: st_count,
          workflow_transitions: wt_count,
          tasks: task_count,
          sections: sec_count,
          code_refs: ref_count,
          hierarchy: hier_count,
          dependencies: dep_count,
          step_executions: se_count,
          id_maps: %{
            workflows: workflow_map,
            steps: step_map,
            tasks: task_map
          }
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # --- Workflows ---

  @spec import_workflows(project(), user(), [json_map()]) ::
          {:ok, id_map(), non_neg_integer()} | {:error, import_error()}
  defp import_workflows(project, user, workflows_data) do
    workflows_data
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}, 0}, fn {wf_data, idx}, {:ok, map, count} ->
      attrs = %{
        "name" => wf_data["name"],
        "description" => wf_data["description"],
        "auto_advance" => wf_data["auto_advance"] || false,
        "display_order" => wf_data["order"] || idx
      }

      changeset =
        Workflow.create_changeset(
          %Workflow{project_id: project.id, user_id: user.id},
          attrs
        )

      case Repo.insert(changeset) do
        {:ok, workflow} ->
          old_id = to_string(wf_data["id"])
          Logger.info("Imported workflow: #{old_id} -> #{workflow.id} (#{wf_data["name"]})")
          {:cont, {:ok, Map.put(map, old_id, workflow.id), count + 1}}

        {:error, changeset} ->
          {:halt, {:error, {:workflow, wf_data["id"], changeset}}}
      end
    end)
  end

  # --- Workflow Steps ---

  @spec import_workflow_steps(user(), id_map(), [json_map()]) ::
          {:ok, id_map(), non_neg_integer(), non_neg_integer()} | {:error, import_error()}
  defp import_workflow_steps(user, workflow_map, workflows_data) do
    Enum.reduce_while(workflows_data, {:ok, %{}, 0, 0}, fn wf_data,
                                                           {:ok, step_map, step_count, st_count} ->
      old_wf_id = to_string(wf_data["id"])
      new_wf_id = Map.fetch!(workflow_map, old_wf_id)

      steps = wf_data["steps"] || []

      case import_steps_for_workflow(user, new_wf_id, steps, step_map, step_count) do
        {:ok, updated_step_map, updated_step_count} ->
          case import_step_transitions_for_workflow(user, steps, updated_step_map, st_count) do
            {:ok, updated_st_count} ->
              {:cont, {:ok, updated_step_map, updated_step_count, updated_st_count}}

            {:error, _} = err ->
              {:halt, err}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @spec import_steps_for_workflow(user(), Ecto.UUID.t(), [json_map()], id_map(), non_neg_integer()) ::
          {:ok, id_map(), non_neg_integer()} | {:error, import_error()}
  defp import_steps_for_workflow(user, new_wf_id, steps, step_map, step_count) do
    Enum.reduce_while(steps, {:ok, step_map, step_count}, fn step_data, {:ok, map, count} ->
      attrs = %{
        "name" => step_data["name"],
        "goal" => step_data["goal"],
        "agents" => step_data["agents"] || [],
        "skills" => step_data["skills"] || [],
        "is_final" => step_data["is_final"] || false,
        "step_order" => step_data["order"]
      }

      changeset =
        %WorkflowStep{workflow_id: new_wf_id, user_id: user.id}
        |> WorkflowStep.create_changeset(attrs)

      case Repo.insert(changeset) do
        {:ok, step} ->
          old_id = to_string(step_data["id"])
          {:cont, {:ok, Map.put(map, old_id, step.id), count + 1}}

        {:error, changeset} ->
          {:halt, {:error, {:workflow_step, step_data["id"], changeset}}}
      end
    end)
  end

  @spec import_step_transitions_for_workflow(user(), [json_map()], id_map(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, import_error()}
  defp import_step_transitions_for_workflow(user, steps, step_map, st_count) do
    Enum.reduce_while(steps, {:ok, st_count}, fn step_data, {:ok, count} ->
      old_from_id = to_string(step_data["id"])
      new_from_id = Map.fetch!(step_map, old_from_id)
      transitions = step_data["transitions"] || []

      result =
        Enum.reduce_while(transitions, {:ok, count}, fn old_to_id, {:ok, c} ->
          old_to_id = to_string(old_to_id)

          case Map.fetch(step_map, old_to_id) do
            {:ok, new_to_id} ->
              changeset =
                %StepTransition{user_id: user.id}
                |> StepTransition.create_changeset(%{
                  "from_step_id" => new_from_id,
                  "to_step_id" => new_to_id
                })

              case Repo.insert(changeset) do
                {:ok, _} -> {:cont, {:ok, c + 1}}
                {:error, cs} -> {:halt, {:error, {:step_transition, old_from_id, old_to_id, cs}}}
              end

            :error ->
              Logger.warning(
                "Skipping step transition: target step #{old_to_id} not found in map"
              )

              {:cont, {:ok, c}}
          end
        end)

      case result do
        {:ok, updated_count} -> {:cont, {:ok, updated_count}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # --- Backfill initial_step_id ---

  @spec backfill_initial_step_ids(id_map(), id_map(), [json_map()]) ::
          {:ok, non_neg_integer()} | {:error, import_error()}
  defp backfill_initial_step_ids(workflow_map, step_map, workflows_data) do
    Enum.reduce_while(workflows_data, {:ok, 0}, fn wf_data, {:ok, count} ->
      old_wf_id = to_string(wf_data["id"])
      new_wf_id = Map.fetch!(workflow_map, old_wf_id)

      case wf_data["initial_step_id"] do
        nil ->
          {:cont, {:ok, count}}

        old_step_id ->
          old_step_id = to_string(old_step_id)

          case Map.fetch(step_map, old_step_id) do
            {:ok, new_step_id} ->
              workflow = Repo.get!(Workflow, new_wf_id)

              changeset =
                workflow
                |> Workflow.update_changeset(%{"initial_step_id" => new_step_id})

              case Repo.update(changeset) do
                {:ok, _} -> {:cont, {:ok, count + 1}}
                {:error, cs} -> {:halt, {:error, {:backfill_initial_step, old_wf_id, cs}}}
              end

            :error ->
              Logger.warning(
                "Skipping initial_step_id for workflow #{old_wf_id}: step #{old_step_id} not found"
              )

              {:cont, {:ok, count}}
          end
      end
    end)
  end

  # --- Workflow Transitions ---

  @spec import_workflow_transitions(user(), id_map(), id_map(), [json_map()]) ::
          {:ok, non_neg_integer()} | {:error, import_error()}
  defp import_workflow_transitions(user, workflow_map, step_map, transitions_data) do
    Enum.reduce_while(transitions_data, {:ok, 0}, fn wt_data, {:ok, count} ->
      old_from = to_string(wt_data["from_workflow_id"])
      old_to = to_string(wt_data["to_workflow_id"])

      with {:ok, new_from} <- Map.fetch(workflow_map, old_from),
           {:ok, new_to} <- Map.fetch(workflow_map, old_to) do
        target_step_id =
          case wt_data["target_step"] do
            nil -> nil
            old_step_id -> Map.get(step_map, to_string(old_step_id))
          end

        attrs = %{
          "from_workflow_id" => new_from,
          "to_workflow_id" => new_to,
          "label" => wt_data["label"],
          "target_step_id" => target_step_id
        }

        changeset =
          %WorkflowTransition{user_id: user.id}
          |> WorkflowTransition.create_changeset(attrs)

        case Repo.insert(changeset) do
          {:ok, _} -> {:cont, {:ok, count + 1}}
          {:error, cs} -> {:halt, {:error, {:workflow_transition, old_from, old_to, cs}}}
        end
      else
        :error ->
          Logger.warning(
            "Skipping workflow transition #{old_from} -> #{old_to}: workflow not found in map"
          )

          {:cont, {:ok, count}}
      end
    end)
  end

  # --- Tasks ---

  @spec import_tasks(project(), user(), id_map(), id_map(), [json_map()]) ::
          {:ok, id_map(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:error, import_error()}
  defp import_tasks(project, user, workflow_map, step_map, tasks_data) do
    Enum.reduce_while(tasks_data, {:ok, %{}, 0, 0, 0}, fn task_data,
                                                          {:ok, task_map, task_count, sec_count,
                                                           ref_count} ->
      workflow_id = resolve_id(workflow_map, task_data["workflow_id"])
      current_step_id = resolve_id(step_map, task_data["current_step_id"])

      sections_attrs =
        (task_data["sections"] || [])
        |> Enum.map(fn sec ->
          %{
            "section_type" => sec["section_type"],
            "content" => sec["content"],
            "section_order" => sec["order"]
          }
        end)

      attrs = %{
        "title" => task_data["title"],
        "description" => task_data["description"],
        "level" => task_data["level"],
        "priority" => task_data["priority"],
        "needs_human_review" => task_data["needs_human_review"] || false,
        "revision_feedback" => task_data["revision_feedback"],
        "sections" => sections_attrs
      }

      completed_at = parse_datetime(task_data["completed_at"])

      changeset =
        %Task{
          project_id: project.id,
          user_id: user.id,
          workflow_id: workflow_id,
          current_step_id: current_step_id
        }
        |> Task.create_changeset(attrs)
        |> maybe_put_completed_at(completed_at)

      case Repo.insert(changeset) do
        {:ok, task} ->
          old_id = to_string(task_data["id"])
          new_sec_count = sec_count + length(sections_attrs)

          refs = task_data["refs"] || []

          case insert_code_refs(user, task, refs) do
            {:ok, inserted_ref_count} ->
              {:cont,
               {:ok, Map.put(task_map, old_id, task.id), task_count + 1, new_sec_count,
                ref_count + inserted_ref_count}}

            {:error, _} = err ->
              {:halt, err}
          end

        {:error, changeset} ->
          {:halt, {:error, {:task, task_data["id"], changeset}}}
      end
    end)
  end

  @spec insert_code_refs(user(), %{:id => Ecto.UUID.t(), optional(atom()) => term()}, [json_map()]) ::
          {:ok, non_neg_integer()} | {:error, import_error()}
  defp insert_code_refs(_user, _task, []), do: {:ok, 0}

  defp insert_code_refs(user, task, refs) do
    Enum.reduce_while(refs, {:ok, 0}, fn ref_data, {:ok, count} ->
      attrs = %{
        "path" => ref_data["file_spec"],
        "name" => ref_data["name"],
        "description" => ref_data["description"]
      }

      changeset =
        %CodeRef{task_id: task.id, user_id: user.id}
        |> CodeRef.changeset(attrs)

      case Repo.insert(changeset) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, cs} -> {:halt, {:error, {:code_ref, task.id, cs}}}
      end
    end)
  end

  # --- Task Hierarchy ---

  @spec import_hierarchy(user(), id_map(), json_map()) ::
          {:ok, non_neg_integer()} | {:error, import_error()}
  defp import_hierarchy(user, task_map, relationships_data) do
    child_of = relationships_data["child_of"] || []

    Enum.reduce_while(child_of, {:ok, 0}, fn rel, {:ok, count} ->
      old_child = to_string(rel["child_id"])
      old_parent = to_string(rel["parent_id"])

      with {:ok, new_child} <- Map.fetch(task_map, old_child),
           {:ok, new_parent} <- Map.fetch(task_map, old_parent) do
        changeset =
          %TaskHierarchy{parent_id: new_parent, child_id: new_child, user_id: user.id}
          |> TaskHierarchy.changeset()

        case Repo.insert(changeset) do
          {:ok, _} -> {:cont, {:ok, count + 1}}
          {:error, cs} -> {:halt, {:error, {:hierarchy, old_child, old_parent, cs}}}
        end
      else
        :error ->
          Logger.warning(
            "Skipping hierarchy: child=#{old_child} parent=#{old_parent} (task not found)"
          )

          {:cont, {:ok, count}}
      end
    end)
  end

  # --- Task Dependencies ---

  @spec import_dependencies(user(), id_map(), json_map()) ::
          {:ok, non_neg_integer()} | {:error, import_error()}
  defp import_dependencies(user, task_map, relationships_data) do
    depends_on = relationships_data["depends_on"] || []

    Enum.reduce_while(depends_on, {:ok, 0}, fn rel, {:ok, count} ->
      old_task = to_string(rel["task_id"])
      old_dep = to_string(rel["depends_on_id"])

      with {:ok, new_task} <- Map.fetch(task_map, old_task),
           {:ok, new_dep} <- Map.fetch(task_map, old_dep) do
        changeset =
          %TaskDependency{task_id: new_task, depends_on_id: new_dep, user_id: user.id}
          |> TaskDependency.changeset()

        case Repo.insert(changeset) do
          {:ok, _} -> {:cont, {:ok, count + 1}}
          {:error, cs} -> {:halt, {:error, {:dependency, old_task, old_dep, cs}}}
        end
      else
        :error ->
          Logger.warning(
            "Skipping dependency: task=#{old_task} depends_on=#{old_dep} (task not found)"
          )

          {:cont, {:ok, count}}
      end
    end)
  end

  # --- Step Executions ---

  @spec import_step_executions(user(), id_map(), id_map(), [json_map()]) ::
          {:ok, non_neg_integer()} | {:error, import_error()}
  defp import_step_executions(user, workflow_map, task_map, executions_data) do
    Enum.reduce_while(executions_data, {:ok, 0}, fn se_data, {:ok, count} ->
      old_task_id = to_string(se_data["task_id"])
      old_wf_id = to_string(se_data["workflow_id"])

      new_task_id = Map.get(task_map, old_task_id)
      new_wf_id = Map.get(workflow_map, old_wf_id)

      if is_nil(new_task_id) do
        Logger.warning("Skipping step execution: task #{old_task_id} not found in map")
        {:cont, {:ok, count}}
      else
        attrs = %{
          "task_id" => new_task_id,
          "workflow_id" => new_wf_id,
          "step_name" => se_data["step_name"],
          "status" => se_data["status"],
          "model" => se_data["model_used"],
          "prompt" => se_data["prompt"],
          "output" => se_data["output"],
          "transition_result" => se_data["transition_result"],
          "duration_ms" => se_data["duration_ms"],
          "cost" => se_data["cost_usd"],
          "context" => se_data["context"]
        }

        changeset =
          %StepExecution{user_id: user.id}
          |> StepExecution.create_changeset(attrs)

        case Repo.insert(changeset) do
          {:ok, _} -> {:cont, {:ok, count + 1}}
          {:error, cs} -> {:halt, {:error, {:step_execution, se_data["id"], cs}}}
        end
      end
    end)
  end

  # --- Helpers ---

  @spec resolve_id(id_map(), term()) :: Ecto.UUID.t() | nil
  defp resolve_id(_id_map, nil), do: nil

  defp resolve_id(id_map, old_id) do
    Map.get(id_map, to_string(old_id))
  end

  @spec parse_datetime(String.t() | nil) :: DateTime.t() | nil
  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  @spec maybe_put_completed_at(Changeset.t(), DateTime.t() | nil) :: Changeset.t()
  defp maybe_put_completed_at(changeset, nil), do: changeset

  defp maybe_put_completed_at(changeset, %DateTime{} = dt) do
    Changeset.put_change(changeset, :completed_at, dt)
  end
end
