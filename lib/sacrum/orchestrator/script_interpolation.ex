defmodule Sacrum.Orchestrator.ScriptInterpolation do
  @moduledoc false
  @type t :: %__MODULE__{object: %Solid.Object{} | %Solid.Tags.CycleTag{}}
  defstruct [:object]
end

defimpl Solid.Renderable, for: Sacrum.Orchestrator.ScriptInterpolation do
  alias Sacrum.Orchestrator.ScriptInterpolation

  @impl true
  @spec render(ScriptInterpolation.t(), Solid.Context.t(), keyword()) ::
          {iodata(), Solid.Context.t()}
  def render(%ScriptInterpolation{object: %Solid.Tags.CycleTag{} = tag}, context, options) do
    {context, argument} = Solid.Context.run_cycle(context, tag.name, tag.values)

    render(
      %ScriptInterpolation{object: %Solid.Object{loc: tag.loc, argument: argument, filters: []}},
      context,
      options
    )
  end

  def render(%ScriptInterpolation{object: object}, context, options) do
    {:ok, value, context} = Solid.Argument.get(object.argument, context, object.filters, options)

    if is_map(value) or is_list(value) do
      throw(
        {:script_interpolation_error,
         "object and array values are available in context for daemon variable binding; they cannot be interpolated into script source"}
      )
    end

    {:ok, result, context} =
      Solid.Argument.render(%Solid.Literal{value: value, loc: object.loc}, context, [], options)

    {result, context}
  end
end
