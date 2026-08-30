defmodule Sacrum.Routing.HandoffTemplate do
  @moduledoc """
  Validates and renders structured deterministic-route handoff templates.

  Templates are JSON objects whose string values may contain closed
  `{{ dotted.path }}` interpolations. An interpolation that occupies the whole
  string preserves the referenced JSON value's type; embedded interpolations
  are limited to scalar values and produce a string. No expressions, filters,
  function calls, or arbitrary code are evaluated.
  """

  alias Sacrum.Routing.{RouteContext, Traverse}

  @interpolation ~r/{{\s*([^{}]*?)\s*}}/
  @exact_interpolation ~r/\A{{\s*([^{}]*?)\s*}}\z/
  @segment ~r/^[A-Za-z_][A-Za-z0-9_-]*$/

  @type template :: map()
  @type error :: %{code: atom(), path: String.t(), message: String.t()}

  @doc """
  Validates an optional handoff template and normalizes an empty object to
  `nil`, which means no handoff is delivered.
  """
  @spec decode(term(), String.t()) :: {:ok, template() | nil} | {:error, error()}
  def decode(template, path) when is_map(template) do
    with :ok <- validate(template, path) do
      if map_size(template) == 0, do: {:ok, nil}, else: {:ok, template}
    end
  end

  def decode(_template, path),
    do: {:error, error(:route_handoff_template_invalid, path, "must be an object")}

  @doc """
  Renders a validated template with the closed route-step context.

  Runtime validation is intentional: it keeps a corrupted persisted
  configuration from causing a partial route transition and makes failures
  actionable before the route transaction starts.
  """
  @spec render(template() | nil, RouteContext.t(), String.t()) ::
          {:ok, map() | nil} | {:error, error()}
  def render(nil, _context, _path), do: {:ok, nil}

  def render(template, context, path) when is_map(template) do
    with :ok <- validate(template, path),
         {:ok, rendered} <-
           render_value(template, RouteContext.interpolation_context(context), path) do
      normalize_rendered_handoff(rendered, path)
    end
  end

  def render(_template, _context, path),
    do: {:error, error(:route_handoff_render_failed, path, "must render to an object")}

  @doc false
  @spec validate(term(), String.t()) :: :ok | {:error, error()}
  def validate(template, path) when is_map(template), do: validate_map(template, path)

  def validate(_template, path),
    do: {:error, error(:route_handoff_template_invalid, path, "must be an object")}

  defp validate_map(template, path) do
    if Enum.all?(Map.keys(template), &is_binary/1) do
      template
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Traverse.each_while(fn {key, value}, _index ->
        validate_value(value, path_for_key(path, key))
      end)
    else
      {:error, error(:route_handoff_template_invalid, path, "must use string keys")}
    end
  end

  defp validate_value(value, path) when is_map(value), do: validate_map(value, path)

  defp validate_value(value, path) when is_list(value) do
    Traverse.each_while(value, fn item, index -> validate_value(item, "#{path}[#{index}]") end)
  end

  defp validate_value(value, path) when is_binary(value), do: validate_string(value, path)

  defp validate_value(value, _path) when is_number(value) or is_boolean(value) or is_nil(value),
    do: :ok

  defp validate_value(_value, path) do
    {:error,
     error(
       :route_handoff_template_invalid,
       path,
       "must contain only JSON values"
     )}
  end

  defp validate_string(value, path) do
    matches = Regex.scan(@interpolation, value, capture: :all_but_first)
    remainder = Regex.replace(@interpolation, value, "")

    if String.contains?(remainder, "{{") or String.contains?(remainder, "}}") do
      {:error,
       error(
         :route_handoff_template_invalid,
         path,
         "contains a malformed interpolation"
       )}
    else
      Traverse.each_while(matches, fn [reference], _index ->
        validate_reference(String.trim(reference), path)
      end)
    end
  end

  defp render_value(template, context, path) when is_map(template) do
    template
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case render_value(value, context, path_for_key(path, key)) do
        {:ok, rendered} -> {:cont, {:ok, Map.put(acc, key, rendered)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp render_value(template, context, path) when is_list(template) do
    Traverse.map_while(template, fn value, index ->
      render_value(value, context, "#{path}[#{index}]")
    end)
  end

  defp render_value(template, context, path) when is_binary(template),
    do: render_string(template, context, path)

  defp render_value(value, _context, _path), do: {:ok, value}

  defp render_string(template, context, path) do
    case Regex.run(@exact_interpolation, template) do
      [_, reference] -> fetch_reference(context, String.trim(reference), path)
      nil -> render_embedded_interpolations(template, context, path)
    end
  end

  defp render_embedded_interpolations(template, context, path) do
    with :ok <- validate_string(template, path) do
      Enum.reduce_while(
        Regex.scan(@interpolation, template),
        {:ok, template},
        fn [match, reference], {:ok, rendered} ->
          replace_interpolation(rendered, match, reference, context, path)
        end
      )
    end
  end

  defp fetch_reference(context, reference, path) do
    with :ok <- validate_reference(reference, path),
         {:ok, value} <- fetch_path(context, String.split(reference, ".")) do
      {:ok, value}
    else
      :error ->
        {:error,
         error(
           :route_handoff_render_failed,
           path,
           "interpolation reference #{inspect(reference)} is missing from the route-step context"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_path(context, parts) do
    Enum.reduce_while(parts, {:ok, context}, fn part, {:ok, value} ->
      fetch_map_value(value, part)
    end)
  end

  defp normalize_rendered_handoff(rendered, _path)
       when is_map(rendered) and map_size(rendered) == 0,
       do: {:ok, nil}

  defp normalize_rendered_handoff(rendered, _path) when is_map(rendered), do: {:ok, rendered}

  defp normalize_rendered_handoff(_rendered, path),
    do: {:error, error(:route_handoff_render_failed, path, "must render to an object")}

  defp replace_interpolation(rendered, match, reference, context, path) do
    with {:ok, value} <- fetch_reference(context, String.trim(reference), path),
         {:ok, replacement} <- stringify_embedded_value(value, path) do
      {:cont, {:ok, String.replace(rendered, match, replacement, global: false)}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp fetch_map_value(value, part) when is_map(value) do
    case Map.fetch(value, part) do
      {:ok, next} -> {:cont, {:ok, next}}
      :error -> {:halt, :error}
    end
  end

  defp fetch_map_value(_value, _part), do: {:halt, :error}

  defp stringify_embedded_value(value, _path) when is_binary(value), do: {:ok, value}

  defp stringify_embedded_value(value, _path) when is_integer(value),
    do: {:ok, Integer.to_string(value)}

  defp stringify_embedded_value(value, _path) when is_float(value),
    do: {:ok, Float.to_string(value)}

  defp stringify_embedded_value(true, _path), do: {:ok, "true"}
  defp stringify_embedded_value(false, _path), do: {:ok, "false"}
  defp stringify_embedded_value(nil, _path), do: {:ok, ""}

  defp stringify_embedded_value(_value, path) do
    {:error,
     error(
       :route_handoff_render_failed,
       path,
       "object and array interpolations must occupy the whole string to preserve their JSON type"
     )}
  end

  defp validate_reference(reference, path) do
    if RouteContext.allowed_interpolation_path?(reference) do
      :ok
    else
      {:error,
       error(
         :route_handoff_template_invalid,
         path,
         "interpolation reference #{inspect(reference)} is not allowed"
       )}
    end
  end

  defp valid_segment?(segment), do: Regex.match?(@segment, segment)

  defp path_for_key(path, key) do
    if valid_segment?(key), do: "#{path}.#{key}", else: "#{path}[#{inspect(key)}]"
  end

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
