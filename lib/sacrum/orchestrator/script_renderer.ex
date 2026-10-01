defmodule Sacrum.Orchestrator.ScriptRenderer do
  @moduledoc "Strict Liquid rendering for daemon-owned execute scripts."

  alias Sacrum.Orchestrator.ScriptInterpolation

  @spec render(String.t(), map()) :: {:ok, String.t()} | {:error, map()}
  def render(script, context) do
    case Solid.parse(script) do
      {:ok, template} ->
        case Solid.render(guard_interpolations(template), context,
               strict_variables: true,
               strict_filters: true
             ) do
          {:ok, result, []} -> validate_rendered_script(IO.iodata_to_binary(result))
          {:ok, _partial, errors} -> render_error(errors)
          {:error, errors, _partial} -> render_error(errors)
        end

      {:error, error} ->
        render_error([error])
    end
  rescue
    error in [ArgumentError, Protocol.UndefinedError] -> render_error([error])
  catch
    {:script_interpolation_error, message} -> render_error([%ArgumentError{message: message}])
  end

  # Guard Liquid output nodes only: lists/maps can still be used in loops and
  # conditions, but cannot be converted implicitly to script source text.
  defp guard_interpolations(%Solid.Object{} = object), do: %ScriptInterpolation{object: object}

  defp guard_interpolations(%Solid.Tags.EchoTag{object: object}),
    do: %ScriptInterpolation{object: object}

  defp guard_interpolations(%Solid.Tags.CycleTag{} = tag), do: %ScriptInterpolation{object: tag}

  defp guard_interpolations(value) when is_map(value),
    do: Map.new(:maps.to_list(value), fn {key, nested} -> {key, guard_interpolations(nested)} end)

  defp guard_interpolations(value) when is_list(value),
    do: Enum.map(value, &guard_interpolations/1)

  defp guard_interpolations(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&guard_interpolations/1) |> List.to_tuple()

  defp guard_interpolations(value), do: value

  defp validate_rendered_script(script) do
    if String.trim(script) == "" do
      {:error,
       %{
         code: :step_config_render_failed,
         path: "$.script",
         message: "must not render to an empty script"
       }}
    else
      {:ok, script}
    end
  end

  defp render_error(errors) do
    {:error,
     %{
       code: :step_config_render_failed,
       path: "$.script",
       message: Enum.map_join(errors, "; ", &Exception.message/1)
     }}
  end
end
