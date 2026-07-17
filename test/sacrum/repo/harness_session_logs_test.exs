defmodule Sacrum.Repo.HarnessSessionLogsTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Repo
  alias Sacrum.Repo.{Projects, SessionLogs, StepExecutions, Tasks, Users, Workflows}
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  @migration_file Path.expand(
                    "../../../priv/repo/migrations/20260717200850_allow_harness_session_log_format.exs",
                    __DIR__
                  )

  setup do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "harness-#{unique}@example.com",
        username: "harness_#{unique}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user, %{name: "Harness #{unique}"})
    {:ok, _workflow} = Workflows.insert(project, %{name: "Default"})
    {:ok, task} = Tasks.insert(project.id, user.id, %{title: "Harness rollup"})

    {:ok, execution} =
      StepExecutions.insert(user.id, %{
        project_id: project.id,
        task_id: task.id,
        step_name: "execute"
      })

    %{user: user, project: project, execution: execution}
  end

  test "harness is accepted by both schema and database constraints", context do
    assert SessionLog.supported_formats() == ["openai", "anthropic", "harness"]
    assert SessionLog.default_format() == "anthropic"

    assert {:ok, %SessionLog{format: "harness"}} =
             insert_harness(context, harness_event("schema-event", "schema-stream", 1))

    %{rows: [[constraint_definition]]} =
      Repo.query!("""
      SELECT pg_get_constraintdef(oid)
      FROM pg_constraint
      WHERE conname = 'session_logs_format_check'
      """)

    assert constraint_definition =~ "openai"
    assert constraint_definition =~ "anthropic"
    assert constraint_definition =~ "harness"
  end

  test "migration down refuses to narrow the constraint while harness rows exist", context do
    assert {:ok, _log} =
             insert_harness(context, harness_event("migration-event", "migration-stream", 1))

    Code.require_file(@migration_file)

    error =
      assert_raise Postgrex.Error, fn ->
        migration = Sacrum.Repo.Migrations.AllowHarnessSessionLogFormat
        Repo.query!(apply(migration, :down_guard_sql, []))
      end

    assert Exception.message(error) =~
             "cannot restore session_logs_format_check while harness rows exist"
  end

  test "maps neutral turn deltas and session snapshots without double counting subsets",
       context do
    delta = usage(100, 40, 30, 12, 9_001)

    snapshot =
      session_usage(500, 200, 75, 33, 22_002, context_tokens: 650, context_window: 200_000)

    event =
      harness_event("usage-1", "stream-1", 1,
        turn_delta: delta,
        session_snapshot: snapshot,
        extra: %{"future" => true}
      )

    assert {:ok, log} = insert_harness(context, event)
    assert Jason.decode!(log.content)["data"]["turn_delta"]["cost_microusd"] == 9_001
    assert Jason.decode!(log.content)["data"]["turn_delta"]["tokens"]["reasoning_tokens"] == 12
    assert Jason.decode!(log.content)["data"]["session_snapshot"]["context_window"] == 200_000

    execution = reload(context.execution)
    assert_session(execution, input: 100, cached: 40, output: 30, total: 130)
    assert_context(execution, input: 500, cached: 200, total: 650)
    assert is_nil(execution.cost)
  end

  test "falls back to snapshot input plus output for context total", context do
    snapshot =
      session_usage(80, 20, 15, 3, 10)
      |> Map.put("context_tokens", nil)
      |> Map.put("context_window", nil)

    event =
      harness_event("snapshot-fallback", "stream-1", 1,
        turn_delta: nil,
        session_snapshot: snapshot
      )

    assert {:ok, _log} = insert_harness(context, event)

    execution = reload(context.execution)
    assert_session(execution, input: 0, cached: 0, output: 0, total: 0)
    assert_context(execution, input: 80, cached: 20, total: 95)
  end

  test "accepts explicit null for optional usage objects", context do
    snapshot_only =
      harness_event("nullable-delta", "stream-1", 1,
        turn_delta: nil,
        session_snapshot: session_usage(40, 10, 5, 2, 20, context_tokens: 44)
      )
      |> put_in(["data", "turn_delta"], nil)

    delta_only =
      harness_event("nullable-snapshot", "stream-1", 2,
        turn_delta: usage(7, 2, 3, 1, 10),
        session_snapshot: nil
      )
      |> put_in(["data", "session_snapshot"], nil)

    assert {:ok, _snapshot_log} = insert_harness(context, snapshot_only)
    assert {:ok, _delta_log} = insert_harness(context, delta_only)

    execution = reload(context.execution)
    assert_session(execution, input: 7, cached: 2, output: 3, total: 10)
    assert_context(execution, input: 40, cached: 10, total: 44)
  end

  test "identical harness delivery is idempotent and conflicting content is rejected", context do
    event =
      harness_event("immutable", "stream-1", 1,
        turn_delta: usage(10, 4, 3, 2, 100),
        session_snapshot: session_usage(20, 8, 5, 3, 200, context_tokens: 24)
      )

    assert {:ok, first} = insert_harness(context, event)
    first_execution = reload(context.execution)

    assert {:ok, duplicate} = insert_harness(context, event)
    assert duplicate.id == first.id
    assert duplicate.content == first.content
    assert duplicate.inserted_at == first.inserted_at
    assert duplicate.updated_at == first.updated_at
    assert reload(context.execution).session_total_tokens == first_execution.session_total_tokens

    conflicting = put_in(event, ["data", "turn_delta", "tokens", "input_tokens"], 999)

    assert {:error, :event_identity_conflict} = insert_harness(context, conflicting)

    assert [persisted] = SessionLogs.all(conditions: [step_execution_id: context.execution.id])
    assert persisted.id == first.id
    assert persisted.content == first.content
    assert persisted.inserted_at == first.inserted_at
    assert reload(context.execution).session_total_tokens == first_execution.session_total_tokens
  end

  test "a provider-formatted write cannot replace an existing harness event key", context do
    event = harness_event("protected", "stream-1", 1, turn_delta: usage(3, 1, 2, 1, 5))
    assert {:ok, first} = insert_harness(context, event)

    assert {:error, :event_identity_conflict} =
             SessionLogs.insert(context.user.id, %{
               project_id: context.project.id,
               step_execution_id: context.execution.id,
               format: "anthropic",
               logical_key: "harness:protected",
               content: Jason.encode!(%{"usage" => %{"input_tokens" => 999}})
             })

    assert Repo.get!(SessionLog, first.id).format == "harness"
    assert reload(context.execution).session_total_tokens == 5
  end

  test "malformed and unsupported rows remain stored and do not block later valid usage",
       context do
    malformed_rows = [
      {"harness:not-json", "not json"},
      {"harness:wrong-version",
       harness_event("wrong-version", "stream-1", 1) |> Map.put("version", 2) |> Jason.encode!()},
      {"harness:malformed",
       harness_event("malformed", "stream-1", 2,
         turn_delta: %{
           "tokens" => %{
             "input_tokens" => "10",
             "cached_input_tokens" => 1,
             "output_tokens" => 2,
             "reasoning_tokens" => 1
           },
           "cost_microusd" => 3
         },
         session_snapshot: session_usage(50, 10, 5, 1, 8)
       )
       |> Jason.encode!()},
      {"harness:unknown",
       harness_event("unknown", "stream-1", 3,
         type: "future_usage",
         data: %{"usage" => usage(100, 30, 20, 10, 500)}
       )
       |> Jason.encode!()},
      {"harness:not-the-event-id",
       harness_event("key-mismatch", "stream-1", 4, turn_delta: usage(100, 30, 20, 10, 500))
       |> Jason.encode!()},
      {"harness:missing-timestamp",
       harness_event("missing-timestamp", "stream-1", 5)
       |> Map.delete("timestamp")
       |> Jason.encode!()},
      {"harness:bad-semantics",
       harness_event("bad-semantics", "stream-1", 6)
       |> Map.put("semantics", "replace")
       |> Jason.encode!()},
      {"harness:bad-correlation",
       harness_event("bad-correlation", "stream-1", 7)
       |> Map.put("correlation", %{"run_id" => 123})
       |> Jason.encode!()},
      {"harness:bad-provider-sequence",
       harness_event("bad-provider-sequence", "stream-1", 8)
       |> Map.put("provider_sequence", "9")
       |> Jason.encode!()}
    ]

    for {logical_key, content} <- malformed_rows do
      assert {:ok, %SessionLog{} = stored} =
               SessionLogs.insert(context.user.id, %{
                 project_id: context.project.id,
                 step_execution_id: context.execution.id,
                 format: "harness",
                 logical_key: logical_key,
                 content: content
               })

      assert Repo.get!(SessionLog, stored.id).content == content
      assert_session(reload(context.execution), input: 0, cached: 0, output: 0, total: 0)
      assert_context(reload(context.execution), input: 0, cached: 0, total: 0)
    end

    valid =
      harness_event("valid-after-malformed", "stream-1", 5, turn_delta: usage(7, 2, 4, 1, 9))

    assert {:ok, _log} = insert_harness(context, valid)

    assert length(SessionLogs.all(conditions: [step_execution_id: context.execution.id])) ==
             length(malformed_rows) + 1

    assert_session(reload(context.execution), input: 7, cached: 2, output: 4, total: 11)
  end

  test "terminal outcome usage and recursively nested usage are ignored", context do
    for {id, type} <- [{"turn-end", "turn_finished"}, {"run-end", "run_finished"}] do
      terminal =
        harness_event(id, "stream-1", 1,
          type: type,
          data: %{
            "status" => "completed",
            "usage" => usage(500, 200, 100, 50, 1_000),
            "result" => %{"usage" => usage(900, 300, 200, 70, 2_000)}
          }
        )

      assert {:ok, _log} = insert_harness(context, terminal)
    end

    assert_session(reload(context.execution), input: 0, cached: 0, output: 0, total: 0)
    assert_context(reload(context.execution), input: 0, cached: 0, total: 0)
  end

  test "a malformed snapshot invalidates the valid delta atomically", context do
    event =
      harness_event("atomic", "stream-1", 1,
        turn_delta: usage(10, 3, 4, 2, 20),
        session_snapshot: %{
          "tokens" => %{
            "input_tokens" => 50,
            "cached_input_tokens" => 10,
            "output_tokens" => 5
          },
          "cost_microusd" => 100
        }
      )

    assert {:ok, _log} = insert_harness(context, event)
    assert_session(reload(context.execution), input: 0, cached: 0, output: 0, total: 0)
    assert_context(reload(context.execution), input: 0, cached: 0, total: 0)
  end

  test "context replay selects highest sequence per stream then latest inserted stream",
       context do
    high_sequence =
      harness_event("stream-a-high", "stream-a", 8,
        timestamp: "2099-01-01T00:00:00Z",
        provider_sequence: 999,
        turn_delta: usage(8, 2, 1, 1, 10),
        session_snapshot: session_usage(80, 8, 2, 1, 10, context_tokens: 88)
      )

    low_sequence_later =
      harness_event("stream-a-low", "stream-a", 2,
        timestamp: "2100-01-01T00:00:00Z",
        provider_sequence: 1_000,
        turn_delta: usage(2, 1, 2, 1, 10),
        session_snapshot: session_usage(20, 2, 1, 1, 10, context_tokens: 22)
      )

    other_stream_latest =
      harness_event("stream-b", "stream-b", 1,
        timestamp: "2000-01-01T00:00:00Z",
        provider_sequence: 1,
        turn_delta: usage(4, 1, 3, 1, 10),
        session_snapshot: session_usage(60, 6, 4, 2, 10, context_tokens: 66)
      )

    assert {:ok, high_log} = insert_harness(context, high_sequence)
    assert {:ok, _low_log} = insert_harness(context, low_sequence_later)
    assert_session(reload(context.execution), input: 10, cached: 3, output: 3, total: 13)
    assert_context(reload(context.execution), input: 80, cached: 8, total: 88)

    assert {:ok, _other_log} = insert_harness(context, other_stream_latest)
    assert_session(reload(context.execution), input: 14, cached: 4, output: 6, total: 20)
    assert_context(reload(context.execution), input: 60, cached: 6, total: 66)

    assert {:ok, replayed} = insert_harness(context, high_sequence)
    assert replayed.id == high_log.id
    assert replayed.inserted_at == high_log.inserted_at
    assert_session(reload(context.execution), input: 14, cached: 4, output: 6, total: 20)
    assert_context(reload(context.execution), input: 60, cached: 6, total: 66)
  end

  test "mixed provider and harness formats are additive without semantic deduplication",
       context do
    assert {:ok, _anthropic} =
             SessionLogs.insert(context.user.id, %{
               project_id: context.project.id,
               step_execution_id: context.execution.id,
               format: "anthropic",
               content:
                 Jason.encode!(%{
                   "usage" => %{
                     "input_tokens" => 10,
                     "cache_creation_input_tokens" => 2,
                     "cache_read_input_tokens" => 3,
                     "output_tokens" => 4
                   }
                 })
             })

    assert {:ok, _openai} =
             SessionLogs.insert(context.user.id, %{
               project_id: context.project.id,
               step_execution_id: context.execution.id,
               format: "openai",
               content:
                 Jason.encode!(%{
                   "response" => %{
                     "usage" => %{
                       "input_tokens" => 20,
                       "cached_input_tokens" => 5,
                       "output_tokens" => 6
                     }
                   }
                 })
             })

    harness =
      harness_event("mixed-harness", "stream-1", 1,
        turn_delta: usage(30, 7, 8, 3, 100),
        session_snapshot: session_usage(90, 9, 10, 4, 200, context_tokens: 95)
      )

    assert {:ok, _harness} = insert_harness(context, harness)

    execution = reload(context.execution)
    assert_session(execution, input: 65, cached: 15, output: 18, total: 83)
    assert_context(execution, input: 90, cached: 9, total: 95)
  end

  test "updating an older provider key preserves deterministic harness context", context do
    provider_attrs = %{
      project_id: context.project.id,
      step_execution_id: context.execution.id,
      format: "anthropic",
      logical_key: "system/thinking_tokens",
      content: anthropic_content(10, 2, 3, 4)
    }

    assert {:ok, provider_log} = SessionLogs.insert(context.user.id, provider_attrs)

    harness =
      harness_event("mixed-context", "stream-1", 1,
        turn_delta: usage(30, 7, 8, 3, 100),
        session_snapshot: session_usage(90, 9, 10, 4, 200, context_tokens: 95)
      )

    assert {:ok, harness_log} = insert_harness(context, harness)
    assert_context(reload(context.execution), input: 90, cached: 9, total: 95)

    assert {:ok, updated_provider} =
             SessionLogs.insert(context.user.id, %{
               provider_attrs
               | content: anthropic_content(20, 4, 5, 6)
             })

    assert updated_provider.id == provider_log.id
    assert_session(reload(context.execution), input: 59, cached: 12, output: 14, total: 73)
    assert_context(reload(context.execution), input: 90, cached: 9, total: 95)

    assert {:ok, replayed_harness} = insert_harness(context, harness)
    assert replayed_harness.id == harness_log.id
    assert_session(reload(context.execution), input: 59, cached: 12, output: 14, total: 73)
    assert_context(reload(context.execution), input: 90, cached: 9, total: 95)
  end

  test "legacy keyed refresh remains replace-on-conflict", context do
    attrs = %{
      project_id: context.project.id,
      step_execution_id: context.execution.id,
      format: "anthropic",
      logical_key: "system/thinking_tokens",
      content: anthropic_content(10, 2, 3, 4)
    }

    assert {:ok, first} = SessionLogs.insert(context.user.id, attrs)

    assert {:ok, updated} =
             SessionLogs.insert(context.user.id, %{
               attrs
               | content: anthropic_content(20, 4, 5, 6)
             })

    assert updated.id == first.id
    assert updated.content != first.content
    assert_session(reload(context.execution), input: 29, cached: 5, output: 6, total: 35)
    assert_context(reload(context.execution), input: 29, cached: 5, total: 35)
  end

  defp insert_harness(context, event) do
    SessionLogs.insert(context.user.id, %{
      project_id: context.project.id,
      step_execution_id: context.execution.id,
      format: "harness",
      logical_key: "harness:#{event["event_id"]}",
      content: Jason.encode!(event)
    })
  end

  defp harness_event(id, stream_id, sequence, opts \\ []) do
    default_data = %{
      "turn_delta" => Keyword.get(opts, :turn_delta, usage(1, 0, 1, 0, 0)),
      "session_snapshot" => Keyword.get(opts, :session_snapshot)
    }

    data =
      opts
      |> Keyword.get(:data, default_data)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    %{
      "version" => 1,
      "event_id" => id,
      "stream_id" => stream_id,
      "sequence" => sequence,
      "correlation" => %{},
      "timestamp" => Keyword.get(opts, :timestamp, "2026-07-17T00:00:00Z"),
      "semantics" => "snapshot",
      "provider_sequence" => Keyword.get(opts, :provider_sequence),
      "type" => Keyword.get(opts, :type, "usage"),
      "data" => data
    }
  end

  defp usage(input, cached, output, reasoning, cost) do
    %{
      "tokens" => %{
        "input_tokens" => input,
        "cached_input_tokens" => cached,
        "output_tokens" => output,
        "reasoning_tokens" => reasoning
      },
      "cost_microusd" => cost
    }
  end

  defp session_usage(input, cached, output, reasoning, cost, opts \\ []) do
    usage(input, cached, output, reasoning, cost)
    |> maybe_put("context_tokens", Keyword.get(opts, :context_tokens))
    |> maybe_put("context_window", Keyword.get(opts, :context_window))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp anthropic_content(input, cache_create, cache_read, output) do
    Jason.encode!(%{
      "usage" => %{
        "input_tokens" => input,
        "cache_creation_input_tokens" => cache_create,
        "cache_read_input_tokens" => cache_read,
        "output_tokens" => output
      }
    })
  end

  defp reload(execution), do: Repo.get!(StepExecution, execution.id)

  defp assert_session(execution, expected) do
    assert execution.session_input_tokens == Keyword.fetch!(expected, :input)
    assert execution.session_cache_read_input_tokens == Keyword.fetch!(expected, :cached)
    assert execution.session_output_tokens == Keyword.fetch!(expected, :output)
    assert execution.session_total_tokens == Keyword.fetch!(expected, :total)
  end

  defp assert_context(execution, expected) do
    assert execution.context_window_input_tokens == Keyword.fetch!(expected, :input)
    assert execution.context_window_cache_read_input_tokens == Keyword.fetch!(expected, :cached)
    assert execution.context_window_total_tokens == Keyword.fetch!(expected, :total)
  end
end
