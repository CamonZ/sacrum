defmodule Sacrum.Chat.DirectTrackerOperationExecutor do
  @moduledoc """
  Executes resolved direct tracker operations through Accounts services.

  This module expects `Sacrum.Chat.DirectTrackerOperationResolver` to have
  already resolved and scoped all targets. It does not call GraphQL, shell out
  to the vtb CLI, or route mutations through authoring draft services.
  """

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.Routing.InterWorkflow
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, TaskDependency, TaskSection, Workflow, WorkflowStep}
  alias Sacrum.Repo.{TaskSections, TaskWorkflows}

  @task_fields ~w(
    title
    description
    level
    priority
    tags
    started_at
    completed_at
    worktree
    archived
  )
  @task_create_fields ~w(title description level priority tags worktree)a
  @workflow_step_fields ~w(prompt goal agent_config)
  @argument_atom_keys %{
    "content" => :content,
    "description" => :description,
    "done" => :done,
    "done_at" => :done_at,
    "fields" => :fields,
    "include_sections" => :include_sections,
    "level" => :level,
    "operation" => :operation,
    "prompt" => :prompt,
    "priority" => :priority,
    "section_type" => :section_type,
    "tags" => :tags,
    "title" => :title,
    "worktree" => :worktree
  }

  @spec execute(map()) :: {:ok, map()} | {:error, term()}
  def execute(%{action: "show_task", targets: %{task: %Task{} = task}} = operation) do
    include_sections? = argument_get(arguments(operation), "include_sections", false) == true
    task = if include_sections?, do: Repo.preload(task, :sections), else: task

    {:ok, %{action: "show_task", task: task_result(task, include_sections?)}}
  end

  def execute(%{action: "read_task_sections", targets: %{task: %Task{} = task}} = operation) do
    section_type = argument_get(arguments(operation), "section_type")

    sections = Enum.map(task_sections(task.id, section_type), &section_result/1)

    {:ok, %{action: "read_task_sections", sections: sections}}
  end

  def execute(%{action: "tracker_task_write"} = operation) do
    case argument_get(arguments(operation), "operation") do
      "create" -> create_tracker_task(operation)
      _ -> {:error, :unsupported_direct_tracker_operation}
    end
  end

  def execute(
        %{
          action: "update_task_fields",
          targets: %{task: %Task{} = task}
        } = operation
      ) do
    attrs = operation |> arguments() |> fields_arg() |> Map.take(@task_fields)

    transaction(fn ->
      with {:ok, updated_task} <- Accounts.Tasks.update(task, attrs) do
        {:ok, %{action: "update_task_fields", task: task_result(updated_task, false)}}
      end
    end)
  end

  def execute(%{action: "update_workflow_step", targets: targets} = operation) do
    fields = operation |> arguments() |> fields_arg() |> Map.take(@workflow_step_fields)

    update_workflow_step("update_workflow_step", targets, fields)
  end

  def execute(%{action: "update_step_prompt", targets: targets} = operation) do
    fields = operation |> arguments() |> prompt_only_fields()

    update_workflow_step("update_step_prompt", targets, fields)
  end

  def execute(%{action: "upsert_task_section", targets: targets} = operation) do
    transaction(fn ->
      with %Task{} = task <- Map.get(targets, :task),
           {:ok, section} <-
             upsert_task_section(task, targets, section_attrs(task, arguments(operation))) do
        {:ok,
         %{
           action: "upsert_task_section",
           section: section_result(section)
         }}
      else
        nil -> {:error, :missing_task_target}
        error -> error
      end
    end)
  end

  def execute(%{action: "add_task_dependency", targets: targets}) do
    execute_dependency_action("add_task_dependency", targets, &Accounts.Tasks.add_dependency/2)
  end

  def execute(%{action: "remove_task_dependency", targets: targets}) do
    execute_dependency_action(
      "remove_task_dependency",
      targets,
      &Accounts.Tasks.remove_dependency/2
    )
  end

  def execute(%{
        action: "move_task_to_workflow_step",
        targets: %{
          task: %Task{} = task,
          workflow: %Workflow{} = workflow,
          workflow_step: %WorkflowStep{} = step
        }
      }) do
    transaction(fn ->
      with {:ok, updated_task} <- move_task_to_step(task, workflow, step) do
        {:ok, %{action: "move_task_to_workflow_step", task: task_result(updated_task, false)}}
      end
    end)
  end

  def execute(%{action: action}) when is_binary(action),
    do: {:error, :unsupported_direct_tracker_operation}

  def execute(_operation), do: {:error, :invalid_direct_tracker_operation}

  defp create_tracker_task(operation) do
    targets = Map.get(operation, :targets, %{})
    arguments = arguments(operation)

    transaction(fn ->
      with {:ok, user_id, project_id} <- create_scope(operation, targets),
           {:ok, task} <-
             Accounts.Tasks.insert(user_id, project_id, create_task_attrs(arguments, targets)),
           :ok <- add_task_dependencies(task, Map.get(targets, :depends_on, [])) do
        {:ok,
         %{
           action: "tracker_task_write",
           operation: "create",
           task: create_task_result(task, targets)
         }}
      end
    end)
  end

  defp update_workflow_step(action, targets, fields) do
    with %WorkflowStep{} = step <- Map.get(targets, :workflow_step),
         {:ok, updated_step} <- Accounts.WorkflowSteps.update(step, fields) do
      {:ok,
       %{
         action: action,
         workflow_step: workflow_step_result(updated_step)
       }}
    else
      nil -> {:error, :missing_workflow_step_target}
      error -> error
    end
  end

  defp create_scope(%{scope: %{user_id: user_id, project_id: project_id}}, _targets)
       when is_binary(user_id) and is_binary(project_id) do
    {:ok, user_id, project_id}
  end

  defp create_scope(_operation, %{parent: %Task{user_id: user_id, project_id: project_id}})
       when is_binary(user_id) and is_binary(project_id) do
    {:ok, user_id, project_id}
  end

  defp create_scope(_operation, %{workflow: %Workflow{user_id: user_id, project_id: project_id}})
       when is_binary(user_id) and is_binary(project_id) do
    {:ok, user_id, project_id}
  end

  defp create_scope(_operation, %{
         depends_on: [%Task{user_id: user_id, project_id: project_id} | _]
       })
       when is_binary(user_id) and is_binary(project_id) do
    {:ok, user_id, project_id}
  end

  defp create_scope(_operation, _targets), do: {:error, :missing_create_scope}

  defp create_task_attrs(arguments, targets) do
    arguments
    |> take_argument_fields(@task_create_fields)
    |> maybe_put_target_id(:parent_id, Map.get(targets, :parent))
    |> maybe_put_target_id(:workflow_id, Map.get(targets, :workflow))
  end

  defp take_argument_fields(arguments, fields) do
    fields
    |> Map.new(fn field -> {field, argument_get(arguments, Atom.to_string(field))} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_put_target_id(attrs, key, %{id: id}) when is_binary(id), do: Map.put(attrs, key, id)
  defp maybe_put_target_id(attrs, _key, _target), do: attrs

  defp add_task_dependencies(%Task{} = task, dependencies) when is_list(dependencies) do
    Enum.reduce_while(dependencies, :ok, fn
      %Task{} = depends_on, :ok ->
        case Accounts.Tasks.add_dependency(task, depends_on) do
          {:ok, _dependency} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_dependency_target}}
    end)
  end

  defp add_task_dependencies(_task, _dependencies), do: {:error, :invalid_dependency_target}

  defp execute_dependency_action(action, targets, operation) do
    transaction(fn ->
      with {:ok, task, depends_on} <- dependency_targets(targets),
           {:ok, dependency} <- operation.(task, depends_on) do
        {:ok,
         %{
           action: action,
           dependency: dependency_result(dependency)
         }}
      end
    end)
  end

  defp transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp move_task_to_step(
         %Task{workflow_id: workflow_id} = task,
         %Workflow{id: workflow_id},
         %WorkflowStep{} = step
       ) do
    TaskWorkflows.advance_to_step(task, step.id)
  end

  defp move_task_to_step(%Task{} = task, %Workflow{} = workflow, %WorkflowStep{} = step) do
    InterWorkflow.assign_destination_workflow(task, workflow, step.id, nil)
  end

  defp fields_arg(%{} = arguments) do
    case argument_get(arguments, "fields") do
      %{} = fields -> fields
      _ -> %{}
    end
  end

  defp prompt_only_fields(%{} = arguments) do
    case argument_get(arguments, "prompt") do
      prompt when is_binary(prompt) -> %{"prompt" => prompt}
      _ -> %{}
    end
  end

  defp arguments(%{arguments: arguments}) when is_map(arguments), do: arguments
  defp arguments(_operation), do: %{}

  defp section_attrs(%Task{} = task, %{} = arguments) do
    section_type = argument_get(arguments, "section_type")
    content = argument_get(arguments, "content")

    %{
      "task_id" => task.id,
      "project_id" => task.project_id,
      "section_type" => section_type,
      "content" => content,
      "done" => argument_get(arguments, "done", false),
      "done_at" => argument_get(arguments, "done_at")
    }
  end

  defp upsert_task_section(%Task{} = task, targets, attrs) do
    case section_target(targets) do
      %TaskSection{task_id: task_id} = section when task_id == task.id ->
        Accounts.Sections.update(section, Map.drop(attrs, ["task_id", "project_id"]))

      %TaskSection{} ->
        {:error, :invalid_direct_tracker_operation}

      nil ->
        Accounts.Sections.insert(
          task.user_id,
          Map.put(attrs, "section_order", next_section_order(task.id, attrs["section_type"]))
        )
    end
  end

  defp section_target(targets) when is_map(targets) do
    Map.get(targets, :task_section) || Map.get(targets, :section)
  end

  defp next_section_order(task_id, section_type) when is_binary(section_type) do
    max_order =
      Repo.one(
        from section in TaskSections.query(),
          where: section.task_id == ^task_id and section.section_type == ^section_type,
          select: max(section.section_order)
      )

    (max_order || 0) + 1
  end

  defp next_section_order(_task_id, _section_type), do: nil

  defp task_sections(task_id, section_type) when is_binary(section_type) do
    TaskSections.all(
      conditions: [task_id: task_id, section_type: section_type],
      order_by: [asc: :section_order, asc: :inserted_at]
    )
  end

  defp task_sections(task_id, _section_type) do
    TaskSections.all(
      conditions: [task_id: task_id],
      order_by: [asc: :section_type, asc: :section_order, asc: :inserted_at]
    )
  end

  defp dependency_targets(targets) when is_map(targets) do
    case {Map.get(targets, :task), Map.get(targets, :depends_on)} do
      {%Task{} = task, %Task{} = depends_on} -> {:ok, task, depends_on}
      _ -> {:error, :missing_dependency_targets}
    end
  end

  defp dependency_targets(_targets), do: {:error, :missing_dependency_targets}

  defp task_result(%Task{} = task, include_sections?) do
    result = %{
      id: task.id,
      title: task.title,
      description: task.description,
      level: task.level,
      priority: task.priority,
      tags: task.tags,
      started_at: task.started_at,
      completed_at: task.completed_at,
      worktree: task.worktree,
      archived: task.archived,
      status: task.status,
      project_id: task.project_id,
      workflow_id: task.workflow_id,
      current_step_id: task.current_step_id
    }

    if include_sections? do
      Map.put(result, :sections, Enum.map(task.sections, &section_result/1))
    else
      result
    end
  end

  defp create_task_result(%Task{} = task, targets) do
    task
    |> task_result(false)
    |> Map.drop([:project_id])
    |> Map.merge(%{
      parent: task_summary(Map.get(targets, :parent)),
      depends_on: dependency_summaries(targets),
      workflow: workflow_summary(Map.get(targets, :workflow))
    })
  end

  defp task_summary(%Task{} = task) do
    %{
      id: task.id,
      title: task.title,
      level: task.level,
      status: task.status
    }
  end

  defp task_summary(_task), do: nil

  defp dependency_summaries(%{depends_on: dependencies}) when is_list(dependencies) do
    Enum.map(dependencies, &task_summary/1)
  end

  defp dependency_summaries(_targets), do: []

  defp workflow_summary(%Workflow{} = workflow) do
    %{
      id: workflow.id,
      name: workflow.name
    }
  end

  defp workflow_summary(_workflow), do: nil

  defp workflow_step_result(%WorkflowStep{} = step) do
    %{
      id: step.id,
      name: step.name,
      prompt: step.prompt,
      goal: step.goal,
      agent_config: step.agent_config,
      workflow_id: step.workflow_id,
      project_id: step.project_id,
      step_order: step.step_order,
      step_type: step.step_type
    }
  end

  defp section_result(%TaskSection{} = section) do
    %{
      id: section.id,
      task_id: section.task_id,
      project_id: section.project_id,
      section_type: section.section_type,
      section_order: section.section_order,
      content: section.content,
      done: section.done,
      done_at: section.done_at
    }
  end

  defp dependency_result(%TaskDependency{} = dependency) do
    %{
      id: dependency.id,
      task_id: dependency.task_id,
      depends_on_id: dependency.depends_on_id,
      project_id: dependency.project_id
    }
  end

  defp argument_get(map, key, default \\ nil)

  defp argument_get(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key = Map.fetch!(@argument_atom_keys, key)
        Map.get(map, atom_key, default)
    end
  end
end
