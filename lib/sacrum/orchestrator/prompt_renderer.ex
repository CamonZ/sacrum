defmodule Sacrum.Orchestrator.PromptRenderer do
  @moduledoc """
  Pure template rendering module using Solid/Liquid syntax.

  Undefined variables render as empty values (empty string for interpolation,
  zero-iteration for `{% for %}`, falsy for `{% if %}`). Templates are
  responsible for guarding optional data with conditionals if they want to
  suppress surrounding markup. Parse errors are logged and fall back to the raw
  template so the issue is visible downstream.

  All context map keys must be strings as per Liquid/Solid requirement.
  """

  require Logger

  alias Sacrum.Repo

  @spec render(String.t() | nil, map()) :: {:ok, String.t()}
  def render(nil, _context), do: {:ok, ""}
  def render("", _context), do: {:ok, ""}

  def render(template_string, context) when is_binary(template_string) and is_map(context) do
    case Solid.parse(template_string) do
      {:ok, template} ->
        {:ok, iolist, _} = Solid.render(template, context)
        {:ok, IO.iodata_to_binary(iolist)}

      {:error, error} ->
        Logger.warning("Solid parse error: #{inspect(error)}")
        {:ok, template_string}
    end
  end

  @doc """
  Preloads the task associations needed to build the rendering context,
  avoiding N+1 queries downstream.
  """
  @spec preload_for_rendering(Sacrum.Repo.Schemas.Task.t()) :: Sacrum.Repo.Schemas.Task.t()
  def preload_for_rendering(task) do
    Repo.preload(task, [:sections, :code_refs, :workflow, :current_step])
  end
end
