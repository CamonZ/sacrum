defmodule Sacrum.Orchestrator.PromptRenderer do
  @moduledoc """
  Pure template rendering module using Solid/Liquid syntax.

  Renders Liquid templates with strict variable mode (undefined variables produce errors).
  Handles parse and render errors gracefully by logging warnings and returning the raw template.

  All context map keys must be strings as per Liquid/Solid requirement.
  """

  require Logger

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
