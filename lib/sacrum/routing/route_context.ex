defmodule Sacrum.Routing.RouteContext do
  @moduledoc """
  Builds the closed runtime value used by deterministic routes.

  The predecessor output has already been validated against its declared
  output schema. Predicates read schema-validated `previous_output.<path>`
  values, `task.level`, `task.tags`, and `execution.step_visit_count`; handoff
  templates interpolate the same values. There is no access to the wider
  prompt context.
  """

  @levels MapSet.new(["epic", "ticket", "task"])
  @output_segment ~r/^[A-Za-z0-9_-]+$/

  @type t :: %{
          previous_output: map(),
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
    with {:ok, normalized_task} <- decode_task(task),
         :ok <- validate_visit_count(step_visit_count) do
      {:ok,
       %{
         previous_output: previous_output,
         task: normalized_task,
         execution: %{step_visit_count: step_visit_count}
       }}
    end
  end

  def build(_previous_output, _task, _step_visit_count),
    do: {:error, error(:route_input_invalid, "$", "must include previous output and task maps")}

  @doc """
  Returns a single whitelisted value from a RouteContext.

  Output references (`previous_output.<path>`) return `:missing` when the
  value is absent or `null`; callers must treat that as an unmatched signal,
  not as a value.
  """
  @spec fetch(t(), atom() | String.t()) :: {:ok, term()} | :missing | {:error, error()}
  def fetch(context, :task_level), do: {:ok, get_in(context, [:task, :level])}
  def fetch(context, :task_tags), do: {:ok, get_in(context, [:task, :tags])}

  def fetch(context, :execution_step_visit_count),
    do: {:ok, get_in(context, [:execution, :step_visit_count])}

  def fetch(context, "previous_output." <> path),
    do: fetch_output(context.previous_output, path)

  def fetch(_context, reference),
    do: {:error, error(:route_reference_unknown, "$", "#{inspect(reference)} is not routable")}

  defp fetch_output(data, path) do
    path
    |> String.split(".")
    |> Enum.reduce_while(data, fn
      key, %{} = map when is_map_key(map, key) -> {:cont, Map.fetch!(map, key)}
      _key, _value -> {:halt, nil}
    end)
    |> case do
      nil -> :missing
      value -> {:ok, value}
    end
  end

  @doc """
  Returns the full closed, string-keyed context available to route handoff
  templates.

  The context deliberately contains only the deterministic route-step inputs:
  the schema-validated predecessor output, task level/tags, and the current
  route visit count.
  """
  @spec interpolation_context(t()) :: map()
  def interpolation_context(%{
        previous_output: output,
        task: %{level: level, tags: tags},
        execution: %{step_visit_count: step_visit_count}
      }) do
    %{
      "previous_output" => output,
      "task" => %{"level" => level, "tags" => tags},
      "execution" => %{"step_visit_count" => step_visit_count}
    }
  end

  @doc """
  True when a dotted interpolation path is in the closed route-step context.

  `previous_output.<path>` segments are checked for property-key shape only;
  whether the path is declared by every incoming predecessor's output schema
  is proved when the route is saved (`Sacrum.Routing.RoutePredecessors`).
  """
  @spec allowed_interpolation_path?(String.t()) :: boolean()
  def allowed_interpolation_path?(reference) when is_binary(reference) do
    allowed_interpolation_parts?(String.split(reference, "."))
  end

  defp allowed_interpolation_parts?(["previous_output" | [_ | _] = path]),
    do: Enum.all?(path, &Regex.match?(@output_segment, &1))

  defp allowed_interpolation_parts?(["task", "level"]), do: true
  defp allowed_interpolation_parts?(["task", "tags"]), do: true
  defp allowed_interpolation_parts?(["execution", "step_visit_count"]), do: true
  defp allowed_interpolation_parts?(_parts), do: false

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
