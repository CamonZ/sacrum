defmodule Sacrum.Accounts.SessionLogs.IngestionModelTest do
  @moduledoc """
  Model-based property test for session-log ingestion.

  Daemon-shaped event streams (`Sacrum.HarnessDaemonGen`), interleaved with
  redeliveries, conflicting resends, drains, flushes, process restarts and
  database outages, run against the real ingestion process and a pure model
  of the contract. After every command the reply and the broadcasts must equal
  the model's; whenever writes are settled, the stored rows and the step
  execution's token counters must too. At the end, folding the broadcast text
  deltas and snapshots per item, as a client does, must yield the stored text.

  Not async: the outage trigger locks `session_logs` for the whole test.
  """

  use Sacrum.DataCase, async: false
  use ExUnitProperties

  alias Sacrum.Accounts.SessionLogs
  alias Sacrum.Accounts.SessionLogs.Ingestion
  alias Sacrum.HarnessDaemonGen, as: Gen
  alias Sacrum.Repo.{Projects, Tasks, Users, Workflows}
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.SessionLogs, as: SessionLogRepo

  @moduletag :capture_log
  @settle_timeout 15_000
  @counter_fields ~w(session_input_tokens session_cache_read_input_tokens session_output_tokens session_total_tokens context_window_input_tokens context_window_cache_read_input_tokens context_window_total_tokens)a

  setup do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "ingestion-model-#{unique}@example.com",
        username: "ingestion_model_#{unique}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user, %{name: "Ingestion model #{unique}"})
    {:ok, _workflow} = Workflows.insert(project, %{name: "Default"})
    {:ok, task} = Tasks.insert(project.id, user.id, %{title: "Ingestion model"})

    # Fails every session-log insert while `sacrum.fail_session_log_writes` is
    # on. Created inside the sandbox transaction, so it is rolled back.
    Repo.query!("""
    CREATE FUNCTION sacrum_test_fail_session_log_writes() RETURNS trigger AS $$
    BEGIN
      IF current_setting('sacrum.fail_session_log_writes', true) = 'on' THEN
        RAISE EXCEPTION 'injected session-log write failure';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER sacrum_test_fail_session_log_writes BEFORE INSERT ON session_logs
    FOR EACH ROW EXECUTE FUNCTION sacrum_test_fail_session_log_writes()
    """)

    :ok = SacrumWeb.Endpoint.subscribe("project:#{project.id}")
    %{user: user, project: project, task: task}
  end

  # -- command generation ------------------------------------------------------

  defp commands do
    bind(Gen.events(), fn events ->
      map(list_of(op(), length: length(events)), fn ops ->
        events
        |> Enum.zip(ops)
        |> Enum.flat_map(fn {event, op} -> [{:event, event} | List.wrap(op)] end)
      end)
    end)
  end

  defp op do
    frequency([
      {24, constant(nil)},
      {3, tuple({constant(:redeliver), ref()})},
      {1, tuple({constant(:conflict), ref()})},
      {1, constant(:drain)},
      {1, constant(:flush)},
      {1, constant(:restart)},
      {1, constant(:outage)}
    ])
  end

  # Counts back from the newest event sent.
  defp ref, do: frequency([{3, integer(0..3)}, {1, integer(0..40)}])

  property "ingestion matches the model over daemon-shaped streams", context do
    check all(commands <- commands(), max_runs: 75) do
      model = new_model(context)

      model =
        Enum.reduce(commands, model, fn command, model ->
          model |> step(command) |> assert_broadcasts()
        end)

      model = model |> outage(false) |> step(:flush) |> assert_broadcasts()
      assert_settled(model)
      assert_live_fold_matches_history(model)
      assert_no_delta_stored(model)
    end
  end

  # -- model -------------------------------------------------------------------

  defp new_model(context) do
    {:ok, execution} =
      Sacrum.Repo.StepExecutions.insert(context.user.id, %{
        project_id: context.project.id,
        task_id: context.task.id,
        step_name: "execute"
      })

    %{
      user: context.user,
      execution: execution,
      run: "m#{System.unique_integer([:positive])}",
      # Non-delta events accepted by the running process: logical key => %{id, content}.
      accepted: %{},
      completed: MapSet.new(),
      # Open tool items: key => %{event type => spec entry}.
      open: %{},
      # Stored events: logical key => %{order, id, spec}.
      stored: %{},
      order: 0,
      # Every event sent so far, newest first: %{spec, attrs}.
      sent: [],
      expected_broadcasts: [],
      broadcasts: [],
      outage?: false
    }
  end

  defp step(model, {:event, spec}), do: send_event(model, spec, Gen.attrs(spec, model.run))

  defp step(model, {:redeliver, ref}) do
    case Enum.at(model.sent, rem(ref, max(length(model.sent), 1))) do
      nil -> model
      %{spec: spec, attrs: attrs} -> send_event(model, spec, attrs)
    end
  end

  defp step(model, {:conflict, ref}) do
    non_deltas = Enum.reject(model.sent, &delta?(&1.spec))

    case Enum.at(non_deltas, rem(ref, max(length(non_deltas), 1))) do
      nil ->
        model

      %{spec: spec, attrs: attrs} ->
        content =
          attrs.content
          |> Jason.decode!()
          |> put_in(["data", "conflict"], true)
          |> Jason.encode!()

        send_event(model, %{spec | data: Map.put(spec.data, "conflict", true)}, %{
          attrs
          | content: content
        })
    end
  end

  defp step(model, :drain) do
    model = outage(model, false)
    assert Ingestion.drain(model.execution.id, @settle_timeout) in [:flushed, :idle]
    assert_settled(model)
    model
  end

  defp step(model, :flush) do
    model = outage(model, false)
    assert Ingestion.flush(model.execution.id, @settle_timeout) in [:flushed, :idle]
    model = close(model, fn _key -> true end)
    assert_settled(model)
    model
  end

  # A stop writes everything it holds, open items included. The next event
  # starts a process that seeds itself from what is stored.
  defp step(model, :restart) do
    model = outage(model, false)

    case Registry.lookup(Sacrum.Accounts.SessionLogs.IngestionRegistry, model.execution.id) do
      [{pid, _value}] -> :ok = GenServer.stop(pid)
      [] -> :ok
    end

    model = close(model, fn _key -> true end)
    assert_settled(model)

    stored = Map.values(model.stored)

    %{
      model
      | open: %{},
        accepted:
          Map.new(model.stored, fn {key, entry} -> {key, Map.take(entry, [:id, :content])} end),
        completed:
          for(%{spec: %{role: {:complete, key, _type}}} <- stored, into: MapSet.new(), do: key)
    }
  end

  defp step(model, :outage), do: outage(model, not model.outage?)

  defp outage(%{outage?: on?} = model, on?), do: model

  defp outage(model, on?) do
    Repo.query!("SELECT set_config('sacrum.fail_session_log_writes', $1, false)", [
      if(on?, do: "on", else: "off")
    ])

    %{model | outage?: on?}
  end

  defp send_event(model, spec, attrs) do
    result =
      SessionLogs.insert(
        model.user.id,
        Map.put(attrs, :step_execution_id, model.execution.id)
      )

    model = %{model | sent: [%{spec: spec, attrs: attrs} | model.sent]}

    if delta?(spec) do
      assert {:ok, _log} = result
      {:delta, key} = spec.role

      if MapSet.member?(model.completed, key),
        do: model,
        else: expect_broadcast(model, attrs.logical_key, attrs.content)
    else
      accept(model, spec, attrs, result)
    end
  end

  defp accept(model, spec, attrs, result) do
    case Map.fetch(model.accepted, attrs.logical_key) do
      {:ok, %{id: id, content: content}} when content == attrs.content ->
        assert {:ok, %{id: ^id}} = result
        model

      {:ok, _accepted} ->
        assert {:error, :event_identity_conflict} = result
        model

      :error ->
        assert {:ok, %{id: id}} = result
        entry = %{id: id, content: attrs.content, spec: spec, order: model.order}

        model = %{
          model
          | order: model.order + 1,
            accepted: Map.put(model.accepted, attrs.logical_key, Map.take(entry, [:id, :content]))
        }

        model
        |> expect_broadcast(attrs.logical_key, attrs.content)
        |> place(attrs.logical_key, entry)
    end
  end

  defp place(model, logical_key, %{spec: %{role: {kind, key, type}}} = entry)
       when kind in [:open, :complete] do
    cond do
      MapSet.member?(model.completed, key) ->
        store(model, [{logical_key, entry}])

      kind == :open ->
        %{
          model
          | open:
              Map.update(
                model.open,
                key,
                %{type => {logical_key, entry}},
                &Map.put(&1, type, {logical_key, entry})
              )
        }

      true ->
        {snapshots, open} = Map.pop(model.open, key, %{})

        %{model | open: open, completed: MapSet.put(model.completed, key)}
        |> store(Map.values(Map.put(snapshots, type, {logical_key, entry})))
    end
  end

  defp place(model, logical_key, %{spec: %{role: {:close_stream, stream}}} = entry) do
    model
    |> close(&match?({_kind, ^stream, _id}, &1))
    |> store([{logical_key, entry}])
  end

  defp place(model, logical_key, %{spec: %{role: :point}} = entry),
    do: store(model, [{logical_key, entry}])

  defp close(model, match?) do
    {closing, open} = Map.split_with(model.open, fn {key, _snapshots} -> match?.(key) end)

    Enum.reduce(closing, %{model | open: open}, fn {key, snapshots}, model ->
      %{model | completed: MapSet.put(model.completed, key)} |> store(Map.values(snapshots))
    end)
  end

  defp store(model, entries), do: %{model | stored: Enum.into(entries, model.stored)}

  defp expect_broadcast(model, logical_key, content),
    do: %{model | expected_broadcasts: [{logical_key, content} | model.expected_broadcasts]}

  defp delta?(%{role: {:delta, _key}}), do: true
  defp delta?(_spec), do: false

  # The usage counters the stored usage events imply: `turn_delta` summed;
  # context from each stream's highest-sequence snapshot, the latest accepted
  # of those winning across streams.
  defp expected_counters(model) do
    usage =
      for {_key, %{spec: %{type: "usage"} = spec} = entry} <- model.stored,
          do: Map.put(entry, :data, spec.data)

    total =
      Enum.reduce(usage, {0, 0, 0}, fn entry, {input, cached, output} ->
        case entry.data["turn_delta"] do
          nil -> {input, cached, output}
          delta -> add_tokens({input, cached, output}, delta["tokens"])
        end
      end)

    context =
      usage
      |> Enum.filter(& &1.data["session_snapshot"])
      |> Enum.group_by(& &1.spec.stream_id)
      |> Enum.map(fn {_stream, entries} ->
        Enum.max_by(entries, &{&1.spec.sequence, &1.order})
      end)
      |> Enum.max_by(& &1.order, fn -> nil end)

    {input, cached, output} = total

    {context_input, context_cached, context_total} =
      case context do
        nil ->
          {0, 0, 0}

        %{data: %{"session_snapshot" => snapshot}} ->
          tokens = snapshot["tokens"]

          {tokens["input_tokens"], tokens["cached_input_tokens"],
           snapshot["context_tokens"] || tokens["input_tokens"] + tokens["output_tokens"]}
      end

    %{
      session_input_tokens: input,
      session_cache_read_input_tokens: cached,
      session_output_tokens: output,
      session_total_tokens: input + output,
      context_window_input_tokens: context_input,
      context_window_cache_read_input_tokens: context_cached,
      context_window_total_tokens: context_total
    }
  end

  defp add_tokens({input, cached, output}, tokens) do
    {input + tokens["input_tokens"], cached + tokens["cached_input_tokens"],
     output + tokens["output_tokens"]}
  end

  # -- assertions ----------------------------------------------------------------

  defp assert_broadcasts(model) do
    execution_id = model.execution.id
    received = received_broadcasts(execution_id, [])
    assert received == Enum.reverse(model.expected_broadcasts)
    %{model | expected_broadcasts: [], broadcasts: model.broadcasts ++ received}
  end

  defp received_broadcasts(execution_id, acc) do
    receive do
      %Phoenix.Socket.Broadcast{
        event: "session_log_created",
        payload: %{step_execution_id: ^execution_id} = payload
      } ->
        received_broadcasts(execution_id, [{payload.logical_key, payload.content} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Stored rows, in history order, are exactly the model's stored events with
  # the ids they were accepted under, and the counters match them.
  defp assert_settled(model) do
    rows =
      for log <- SessionLogRepo.harness_logs(model.execution.id),
          do: {log.logical_key, log.id, log.content}

    expected =
      model.stored
      |> Enum.sort_by(fn {_key, entry} -> entry.order end)
      |> Enum.map(fn {key, entry} -> {key, entry.id, entry.content} end)

    assert rows == expected

    if rows != [] do
      execution = Repo.get!(StepExecution, model.execution.id)
      assert Map.take(execution, @counter_fields) == expected_counters(model)
    end
  end

  # A client appends text deltas and replaces on a snapshot; for every stored
  # text item, the live view must end on the stored text.
  defp assert_live_fold_matches_history(model) do
    live =
      Enum.reduce(model.broadcasts, %{}, fn {_key, content}, live ->
        case Jason.decode!(content) do
          %{"type" => "text", "correlation" => %{"item_id" => item}} = event ->
            key = {event["stream_id"], item}
            text = event["data"]["text"]

            if event["semantics"] == "delta",
              do: Map.update(live, key, text, &(&1 <> text)),
              else: Map.put(live, key, text)

          _event ->
            live
        end
      end)

    for {_key, %{spec: %{type: "text", role: {:complete, {:text, stream, item}, _}}} = entry} <-
          model.stored do
      assert live[{stream, item}] == entry.spec.data["text"]
    end
  end

  # Usage carries the token counts whatever its semantics; nothing else that
  # streams is ever stored.
  defp assert_no_delta_stored(model) do
    for log <- SessionLogRepo.harness_logs(model.execution.id),
        event = Jason.decode!(log.content),
        event["semantics"] == "delta" do
      assert event["type"] == "usage"
    end
  end
end
