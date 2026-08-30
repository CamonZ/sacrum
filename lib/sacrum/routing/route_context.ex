defmodule Sacrum.Routing.RouteContext do
  @moduledoc """
  Builds the closed runtime value used by deterministic routes.

  It deliberately exposes only the four V1 route references and has no
  database or schema-validation dependencies.
  """

  @levels MapSet.new(["epic", "ticket", "task"])

  @type t :: %{
          previous_output: %{route: %{result: String.t(), handoff: map()}},
          task: %{level: String.t(), tags: [String.t()]},
          execution: %{step_visit_count: pos_integer()}
        }

  @type error :: %{code: atom(), path: String.t(), message: String.t()}

  @doc """
  Builds a RouteContext from JSON-shaped route inputs.

  Both `previous_output` and `task` use string keys at this boundary; the
  returned context uses an internal atom-keyed representation.
  """
  @spec build(map(), map(), term()) :: {:ok, t()} | {:error, error()}
  def build(previous_output, task, step_visit_count)
      when is_map(previous_output) and is_map(task) do
    with {:ok, result, handoff} <- decode_route_output(previous_output),
         {:ok, normalized_task} <- decode_task(task),
         :ok <- validate_visit_count(step_visit_count) do
      {:ok,
       %{
         previous_output: %{route: %{result: result, handoff: handoff}},
         task: normalized_task,
         execution: %{step_visit_count: step_visit_count}
       }}
    end
  end

  def build(_previous_output, _task, _step_visit_count),
    do: {:error, error(:route_input_invalid, "$", "must include previous output and task maps")}

  @doc """
  Returns a single whitelisted value from a RouteContext.
  """
  @spec fetch(t(), atom()) :: {:ok, term()} | {:error, error()}
  def fetch(context, :previous_output_route_result),
    do: {:ok, get_in(context, [:previous_output, :route, :result])}

  def fetch(context, :task_level), do: {:ok, get_in(context, [:task, :level])}
  def fetch(context, :task_tags), do: {:ok, get_in(context, [:task, :tags])}

  def fetch(context, :execution_step_visit_count),
    do: {:ok, get_in(context, [:execution, :step_visit_count])}

  def fetch(_context, reference),
    do: {:error, error(:route_reference_unknown, "$", "#{inspect(reference)} is not routable")}

  @doc """
  Returns the full closed, string-keyed context available to route handoff
  templates.

  The context deliberately contains only the deterministic route-step inputs:
  predecessor route output, task level/tags, and the current route visit
  count. It is not the wider prompt-rendering context.
  """
  @spec interpolation_context(t()) :: map()
  def interpolation_context(%{
        previous_output: %{route: %{result: result, handoff: handoff}},
        task: %{level: level, tags: tags},
        execution: %{step_visit_count: step_visit_count}
      }) do
    %{
      "previous_output" => %{"route" => %{"result" => result, "handoff" => handoff}},
      "task" => %{"level" => level, "tags" => tags},
      "execution" => %{"step_visit_count" => step_visit_count}
    }
  end

  defp decode_route_output(%{"route" => %{"result" => result, "handoff" => handoff}})
       when is_binary(result) and result != "" and is_map(handoff) do
    {:ok, result, handoff}
  end

  defp decode_route_output(_output) do
    {:error,
     error(
       :route_input_invalid,
       "$.previous_output.route",
       "must contain a non-empty result string and handoff object"
     )}
  end

  defp decode_task(%{"level" => level, "tags" => tags}) do
    with :ok <- validate_level(level),
         :ok <- validate_tags(tags) do
      {:ok, %{level: level, tags: tags}}
    end
  end

  defp decode_task(_task),
    do: {:error, error(:route_input_invalid, "$.task", "must contain level and tags")}

  defp validate_level(level) when is_binary(level) do
    if MapSet.member?(@levels, level) do
      :ok
    else
      {:error, error(:route_input_invalid, "$.task.level", "must be epic, ticket, or task")}
    end
  end

  defp validate_level(_level),
    do: {:error, error(:route_input_invalid, "$.task.level", "must be a string")}

  defp validate_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1) do
      :ok
    else
      {:error, error(:route_input_invalid, "$.task.tags", "must contain only strings")}
    end
  end

  defp validate_tags(_tags),
    do: {:error, error(:route_input_invalid, "$.task.tags", "must be an array")}

  defp validate_visit_count(count) when is_integer(count) and count > 0, do: :ok

  defp validate_visit_count(_count),
    do:
      {:error,
       error(:route_input_invalid, "$.execution.step_visit_count", "must be a positive integer")}

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
