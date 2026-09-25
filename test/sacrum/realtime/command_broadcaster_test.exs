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
      step: %{verbose_daemon_logging: false}
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
               worktree: "/tmp/worktree"
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
    assert payload.verbose_daemon_logging
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
