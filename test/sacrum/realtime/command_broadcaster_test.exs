defmodule Sacrum.Realtime.CommandBroadcasterTest do
  use ExUnit.Case, async: true

  alias Sacrum.Realtime.CommandBroadcaster
  alias Sacrum.Repo.Schemas.{Task, TaskWorkspace, WorkflowStep}

  setup do
    user_id = Ecto.UUID.generate()
    daemon_id = Ecto.UUID.generate()
    other_daemon_id = Ecto.UUID.generate()
    project_id = Ecto.UUID.generate()

    for id <- [daemon_id, other_daemon_id] do
      :ok = Sacrum.TestWorkspace.connect_daemon(id, user_id)
      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "daemon:#{id}")
    end

    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project_id}")

    data = %{
      execution: %{
        id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        project_id: project_id,
        user_id: user_id,
        config: %WorkflowStep.Config.LlmInference{agent_config: %{"model" => "test"}}
      },
      task: %Task{workspace: %TaskWorkspace{daemon_id: daemon_id, worktree_path: "/tmp/worktree"}},
      step: %{harness: "codex", verbose_daemon_logging: false}
    }

    %{data: data, daemon_id: daemon_id, other_daemon_id: other_daemon_id, user_id: user_id}
  end

  test "run and cancel target only the selected daemon without database queries", ctx do
    query_ref = make_ref()
    owner = self()

    :ok =
      :telemetry.attach(
        query_ref,
        [:sacrum, :repo, :query],
        fn _, _, _, _ ->
          if self() == owner, do: send(owner, {:query, query_ref})
        end,
        nil
      )

    try do
      topic = "daemon:#{ctx.daemon_id}"
      assert :ok = CommandBroadcaster.broadcast_run_step(ctx.data, ctx.daemon_id)
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "run_step", payload: payload}

      assert payload == %{
               id: ctx.data.execution.id,
               task_id: ctx.data.execution.task_id,
               project_id: ctx.data.execution.project_id,
               prompt: "",
               agent_config: %{"model" => "test"},
               worktree: "/tmp/worktree",
               harness: "codex"
             }

      assert :ok = CommandBroadcaster.broadcast_cancel_step(ctx.data.execution, ctx.daemon_id)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "cancel_step",
        payload: cancel
      }

      assert cancel == %{
               step_execution_id: ctx.data.execution.id,
               task_id: ctx.data.execution.task_id,
               project_id: ctx.data.execution.project_id
             }

      refute_receive %Phoenix.Socket.Broadcast{}
      refute_received {:query, ^query_ref}
    after
      :telemetry.detach(query_ref)
    end
  end

  test "preserves optional output schema and verbose logging", ctx do
    schema = %{"type" => "object"}
    data = ctx.data
    data = put_in(data.execution.config.output_schema, schema)
    data = put_in(data.step.verbose_daemon_logging, true)
    assert :ok = CommandBroadcaster.broadcast_run_step(data, ctx.daemon_id)
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
    assert payload.output_schema == schema
    assert payload.harness == "codex"
    assert payload.verbose_daemon_logging
  end

  test "execute wire payload uses only the saved execute snapshot and envelope", ctx do
    config = %WorkflowStep.Config.Execute{
      version: 1,
      script: "transform(execution.previous_output)",
      context: %{
        "task" => %{},
        "execution" => %{},
        "inputs" => %{},
        "steps" => %{},
        "workflow" => %{},
        "artifacts" => %{}
      },
      output_schema: %{"type" => "object"}
    }

    data = ctx.data
    data = put_in(data.execution.config, config)
    # Even a mutable step carrying inference metadata cannot affect this request.
    data =
      Map.put(data, :step, %WorkflowStep{
        harness: "codex",
        config: %WorkflowStep.Config.LlmInference{prompt: "changed"}
      })

    assert :ok = CommandBroadcaster.broadcast_run_step(data, ctx.daemon_id)
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}

    assert payload == %{
             id: data.execution.id,
             task_id: data.execution.task_id,
             project_id: data.execution.project_id,
             worktree: "/tmp/worktree",
             step_type: "execute",
             version: 1,
             script: config.script,
             context: config.context,
             output_schema: config.output_schema
           }

    for value <- [nil, false, 36, "", [], %{}] do
      context = put_in(config.context["execution"]["previous_output"], value)
      data = put_in(data.execution.config.context, context)
      assert :ok = CommandBroadcaster.broadcast_run_step(data, ctx.daemon_id)
      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert Map.fetch!(payload, :context) === context

      refute Enum.any?(
               [:input, :harness, :agent_config, :provider, :model, :prompt],
               &Map.has_key?(payload, &1)
             )
    end
  end

  test "sends the conversation entry for new, resume and fork", ctx do
    root = Ecto.UUID.generate()

    for {fields, session} <- [
          {%{conversation_root_execution_id: root}, %{mode: "new"}},
          {%{conversation_root_execution_id: root, resume_session_id: "native-1"},
           %{mode: "resume", resume_id: "native-1"}},
          {%{
             conversation_root_execution_id: root,
             forked_from_execution_id: Ecto.UUID.generate(),
             resume_session_id: "native-1"
           }, %{mode: "fork", resume_id: "native-1"}}
        ] do
      data = %{ctx.data | execution: Map.merge(ctx.data.execution, fields)}

      assert :ok = CommandBroadcaster.broadcast_run_step(data, ctx.daemon_id)
      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.session == session
    end
  end

  test "requires a daemon id but does not require a live or matching registry session", ctx do
    assert {:error, :workspace_required} = CommandBroadcaster.broadcast_run_step(ctx.data, nil)
    :ok = Sacrum.DaemonConnectionRegistry.unregister(ctx.daemon_id)

    assert :ok = CommandBroadcaster.broadcast_run_step(ctx.data, ctx.daemon_id)
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step"}

    :ok = Sacrum.TestWorkspace.connect_daemon(ctx.daemon_id, Ecto.UUID.generate())

    assert :ok = CommandBroadcaster.broadcast_run_step(ctx.data, ctx.daemon_id)
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step"}
    assert :ok = CommandBroadcaster.broadcast_cancel_step(ctx.data.execution, ctx.daemon_id)
    assert_receive %Phoenix.Socket.Broadcast{event: "cancel_step"}
  end
end
