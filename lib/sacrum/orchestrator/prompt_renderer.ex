defmodule Sacrum.Orchestrator.PromptRenderer do
  @moduledoc """
  Pure template rendering module using Solid/Liquid syntax.

  Renders Liquid templates with strict variable mode (undefined variables produce errors).
  Handles parse and render errors gracefully by logging warnings and returning the raw template.

  All context map keys must be strings as per Liquid/Solid requirement.

  Provides context builders for rendering task, execution, and workflow data in templates.
  """

  require Logger

  alias Sacrum.Repo

  @spec render(String.t() | nil, map()) :: {:ok, String.t()}
  def render(nil, _context), do: {:ok, ""}
  def render("", _context), do: {:ok, ""}

  def render(template_string, context) when is_binary(template_string) and is_map(context) do
    case Solid.parse(template_string) do
      {:ok, template} ->
        render_template(template, context, template_string)

      {:error, error} ->
        Logger.warning("Solid parse error: #{inspect(error)}")
        {:ok, template_string}
    end
  end

  @doc """
  Preloads task associations needed for rendering context.

  Loads sections, code_refs, workflow, and current_step associations to avoid N+1 queries.
  """
  @spec preload_for_rendering(Sacrum.Repo.Schemas.Task.t()) :: Sacrum.Repo.Schemas.Task.t()
  def preload_for_rendering(task) do
    Repo.preload(task, [:sections, :code_refs, :workflow, :current_step])
  end

  @doc """
  Builds a complete string-keyed context map for Solid rendering.

  Combines task, execution, and workflow contexts into a single map suitable
  for Liquid/Solid template rendering. All keys at every nesting level are strings.

  ## Arguments
  - `task` - A Task schema with preloaded associations (use `preload_for_rendering/1`)
  - `execution_data` - A map containing execution history. Can include:
    - `:previous` - Map with `:output` string and other execution details
    - `:retry_count` - Integer count of retries
    - `:duration_ms` - Integer milliseconds for current execution duration
    - `:history` - List of previous executions (maps with :step_name, :status, etc.)
  - `workflow_step` - A WorkflowStep schema with workflow association, or nil

  ## Returns
  A string-keyed map with structure:
  ```
  %{
    "task" => %{
      "id" => "...",
      "title" => "...",
      ...
      "constraints" => [...],
      "goals" => [...],
      ...
    },
    "execution" => %{
      "previous_output" => "...",
      ...
    },
    "workflow" => %{
      "name" => "...",
      ...
    }
  }
  ```
  """
  @spec build_context(
          Sacrum.Repo.Schemas.Task.t(),
          map(),
          Sacrum.Repo.Schemas.WorkflowStep.t() | nil
        ) :: map()
  def build_context(task, execution_data, workflow_step) do
    task_ctx = build_task_context(task)
    execution_ctx = build_execution_context(execution_data)
    workflow_ctx = build_workflow_context(workflow_step, task)

    %{
      "task" => task_ctx,
      "execution" => execution_ctx,
      "workflow" => workflow_ctx
    }
  end

  @doc """
  Builds the task context map.

  Extracts task metadata (id, title, description, level, tags) and groups
  sections by type (constraints, goals, testing_criteria, etc.).
  Also includes code references as a list of maps.

  All keys are strings for Liquid compatibility.
  """
  @spec build_task_context(Sacrum.Repo.Schemas.Task.t()) :: map()
  def build_task_context(task) do
    base_context = %{
      "id" => to_string(task.id),
      "title" => task.title || "",
      "description" => task.description || "",
      "level" => task.level || "",
      "tags" => task.tags || []
    }

    sections_by_type = group_sections_by_type(task.sections)
    code_refs = build_code_refs_list(task.code_refs)

    base_context
    |> Map.merge(sections_by_type)
    |> Map.put("code_refs", code_refs)
  end

  @doc """
  Builds the execution context map.

  Extracts previous execution output, retry count, duration, and execution history.
  All keys are strings for Liquid compatibility.
  """
  @spec build_execution_context(map()) :: map()
  def build_execution_context(execution_data) when is_map(execution_data) do
    previous = execution_data[:previous] || %{}
    previous_output = previous[:output] || ""
    retry_count = execution_data[:retry_count] || 0
    duration_ms = execution_data[:duration_ms]
    history = execution_data[:history] || []

    reject_nil_values(%{
      "previous_output" => to_string(previous_output),
      "retry_count" => retry_count,
      "duration_ms" => duration_ms,
      "history" => build_history_list(history)
    })
  end

  def build_execution_context(_), do: %{}

  @doc """
  Builds the workflow context map.

  Extracts workflow name, current step name/goal, step count, and output schema.
  All keys are strings for Liquid compatibility.
  """
  @spec build_workflow_context(
          Sacrum.Repo.Schemas.WorkflowStep.t() | nil,
          Sacrum.Repo.Schemas.Task.t()
        ) :: map()
  def build_workflow_context(nil, _task), do: %{}

  def build_workflow_context(workflow_step, task) do
    case workflow_step.workflow || task.workflow do
      nil ->
        %{}

      workflow ->
        context = %{
          "name" => workflow.name || "",
          "current_step" => workflow_step.name || "",
          "current_step_goal" => workflow_step.goal || "",
          "step_count" => count_workflow_steps(workflow)
        }

        case workflow_step.output_schema do
          nil -> context
          schema -> Map.put(context, "output_schema", schema)
        end
    end
  end

  # Private helpers

  defp group_sections_by_type(sections) do
    Enum.group_by(
      sections,
      fn section -> normalize_section_type(section.section_type) end,
      fn section -> section.content end
    )
  end

  defp normalize_section_type(type) do
    type_map = %{
      "testing_criterion" => "testing_criteria",
      "constraint" => "constraints",
      "goal" => "goals",
      "anti_pattern" => "anti_patterns",
      "assumption" => "assumptions",
      "checklist_item" => "checklist_items",
      "context" => "context",
      "current_behavior" => "current_behavior",
      "desired_behavior" => "desired_behavior",
      "failure_test" => "failure_tests"
    }

    Map.get(type_map, type, type)
  end

  defp build_code_refs_list(code_refs) do
    Enum.map(code_refs, fn ref ->
      reject_nil_values(%{
        "path" => ref.path || "",
        "line_start" => ref.line_start,
        "line_end" => ref.line_end,
        "name" => ref.name || "",
        "description" => ref.description || ""
      })
    end)
  end

  defp build_history_list(history) when is_list(history) do
    Enum.map(history, fn exec ->
      reject_nil_values(%{
        "step_name" => exec[:step_name] || "",
        "status" => exec[:status] || "",
        "output" => exec[:output] || "",
        "duration_ms" => exec[:duration_ms]
      })
    end)
  end

  defp build_history_list(_), do: []

  defp count_workflow_steps(workflow) do
    case workflow.workflow_steps do
      steps when is_list(steps) -> length(steps)
      _ -> 0
    end
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_k, v} -> v == nil end)
  end

  defp render_template(template, context, fallback_template) do
    case Solid.render(template, context, strict_variables: true) do
      {:ok, iolist, []} ->
        {:ok, IO.iodata_to_binary(iolist)}

      {:ok, _iolist, [_ | _] = errors} ->
        Logger.warning("Solid render error: #{inspect(errors)}")
        {:ok, fallback_template}

      {:error, errors, _partial_result} ->
        Logger.warning("Solid render error: #{inspect(errors)}")
        {:ok, fallback_template}
    end
  end
end
