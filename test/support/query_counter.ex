defmodule Sacrum.QueryCounter do
  @moduledoc """
  Captures the SQL statements `Sacrum.Repo` runs in the calling process.
  """

  @event [:sacrum, :repo, :query]

  @doc "Runs `fun` and returns `{result, statements}` for this process only."
  @spec capture((-> result)) :: {result, [String.t()]} when result: var
  def capture(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @event,
        fn _event, _measurements, %{query: query}, _config ->
          if self() == parent, do: send(parent, {handler_id, query})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(handler_id, acc) do
    receive do
      {^handler_id, query} -> drain(handler_id, [query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
