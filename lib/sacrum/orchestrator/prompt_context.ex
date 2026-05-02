defmodule Sacrum.Orchestrator.PromptContext do
  @moduledoc """
  Builds string-keyed context maps for Solid/Liquid template rendering from
  task, execution, and workflow data.

  All keys at every nesting level are strings — Solid requires it.
  """

  require Logger

  @section_type_map %{
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

  @doc """
  Builds the complete `%{"task" => ..., "execution" => ..., "workflow" => ...}`
  context for Solid rendering.

  `task` should have associations preloaded (see `PromptRenderer.preload_for_rendering/1`).
  `execution_data` is the map returned by `ExecutionHistory.build_execution_data/2`.
  `workflow_step` may be `nil` to omit the workflow section.
  """
  @spec build_context(
          Sacrum.Repo.Schemas.Task.t(),
          map(),
          Sacrum.Repo.Schemas.WorkflowStep.t() | nil
        ) :: map()
  def build_context(task, execution_data, workflow_step) do
    %{
      "task" => build_task_context(task),
      "execution" => build_execution_context(execution_data),
      "workflow" => build_workflow_context(workflow_step, task)
    }
  end

  @doc """
  Builds the task context: id, title, description, level, tags, worktree, code_refs,
  plus one entry per section type (constraints, goals, etc.).
  """
  @spec build_task_context(Sacrum.Repo.Schemas.Task.t()) :: map()
  def build_task_context(task) do
    %{
      "id" => to_string(task.id),
      "title" => task.title || "",
      "description" => task.description || "",
      "level" => task.level || "",
      "tags" => task.tags || [],
      "worktree" => task.worktree || ""
    }
    |> Map.merge(group_sections_by_type(task.sections))
    |> Map.put("code_refs", build_code_refs_list(task.code_refs))
  end

  @doc """
  Builds the execution context: previous output, run counts, duration, history,
  and handoff. Nil values are dropped so they don't pollute templates.
  """
  @spec build_execution_context(map()) :: map()
  def build_execution_context(execution_data) when is_map(execution_data) do
    previous_output = get_in(execution_data, [:previous, :output]) || ""

    reject_nil_values(%{
      "previous_output" => coerce_previous_output(previous_output),
      "run_count" => execution_data[:run_count] || 0,
      "completed_count" => execution_data[:completed_count] || 0,
      "failed_count" => execution_data[:failed_count] || 0,
      "duration_ms" => execution_data[:duration_ms],
      "history" => build_history_list(execution_data[:history] || []),
      "handoff" => execution_data[:handoff]
    })
  end

  def build_execution_context(_), do: %{}

  @doc """
  Builds the workflow context: name, current step name/goal, step count, and
  (when present) the step's output schema.
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

  defp group_sections_by_type(sections) do
    Enum.group_by(
      sections,
      &Map.get(@section_type_map, &1.section_type, &1.section_type),
      & &1.content
    )
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

  defp count_workflow_steps(%{workflow_steps: steps}) when is_list(steps), do: length(steps)
  defp count_workflow_steps(_), do: 0

  defp coerce_previous_output(output) when is_binary(output) or is_map(output) or is_list(output),
    do: output

  defp coerce_previous_output(output), do: to_string(output)

  defp reject_nil_values(map), do: Map.reject(map, fn {_k, v} -> v == nil end)
end
