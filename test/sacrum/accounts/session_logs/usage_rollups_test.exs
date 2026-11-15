defmodule Sacrum.Accounts.SessionLogs.UsageRollupsTest do
  @moduledoc """
  Ingestion folds usage as items complete, which is not acceptance order, and
  reseeds from history in acceptance order after a restart. Both must give the
  same counters.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sacrum.Accounts.SessionLogs.UsageRollups
  alias Sacrum.HarnessDaemonGen
  alias Sacrum.Repo.Schemas.SessionLog

  property "the fold over daemon usage does not depend on the order logs are added" do
    check all(
            events <- HarnessDaemonGen.events(),
            order <- list_of(integer(), length: length(events)),
            max_runs: 300
          ) do
      logs =
        events
        |> Enum.with_index()
        |> Enum.map(fn {spec, index} -> log(spec, index) end)

      shuffled =
        logs |> Enum.zip(order) |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

      assert counters(shuffled) == counters(logs)
    end
  end

  property "turn deltas are summed and outcome usage is ignored" do
    check all(events <- HarnessDaemonGen.events(), max_runs: 300) do
      logs = events |> Enum.with_index() |> Enum.map(fn {spec, index} -> log(spec, index) end)
      counters = counters(logs)

      {input, cached, output} =
        for %{type: "usage", data: %{"turn_delta" => %{"tokens" => tokens}}} <- events,
            reduce: {0, 0, 0} do
          {i, c, o} ->
            {i + tokens["input_tokens"], c + tokens["cached_input_tokens"],
             o + tokens["output_tokens"]}
        end

      assert %{
               session_input_tokens: ^input,
               session_cache_read_input_tokens: ^cached,
               session_output_tokens: ^output
             } = counters

      assert counters.session_total_tokens == input + output
    end
  end

  defp counters(logs),
    do: logs |> Enum.reduce(UsageRollups.new(), &UsageRollups.add(&2, &1)) |> UsageRollups.attrs()

  defp log(spec, index) do
    attrs = HarnessDaemonGen.attrs(spec, "run")

    %SessionLog{
      id: Ecto.UUID.generate(),
      format: "harness",
      logical_key: attrs.logical_key,
      content: attrs.content,
      inserted_at: DateTime.add(~U[2026-11-14 00:00:00.000000Z], index, :microsecond)
    }
  end
end
