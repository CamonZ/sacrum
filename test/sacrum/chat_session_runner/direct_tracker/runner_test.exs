defmodule Sacrum.ChatSessionRunner.DirectTracker.RunnerTest do
  use Sacrum.DataCase

  import Ecto.Query

  alias Sacrum.ChatSessionRunner.DirectTracker.Runner
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "executes resolved operations and records public events", ctx do
    operation = ChatSessionRunnerFixtures.show_task_operation(ctx)

    assert {:ok, [event]} =
             Runner.execute(ctx.session, [operation], %{
               "turn_message_id" => ctx.user_message.id
             })

    assert event.event_type == "chat_direct_tracker_operation.completed"
    assert event.public_payload["action"] == "show_task"
    assert event.public_payload["result"]["id"] == operation.targets.task.id
  end

  test "idempotency is scoped to the current user turn", ctx do
    operation =
      ctx
      |> ChatSessionRunnerFixtures.show_task_operation()
      |> Map.put(:tool_call, %{"id" => "call_reused_by_provider"})

    assert {:ok, [_first_event]} =
             Runner.execute(ctx.session, [operation], %{
               "turn_message_id" => ctx.user_message.id
             })

    {:ok, second_user_message} =
      Sacrum.Accounts.LiveChat.send_message(ctx.user.id, ctx.project.id, ctx.session.id, %{
        content: "Try the same tool call id again",
        client_message_id: "runner-modules-user-2"
      })

    assert {:ok, [_second_event]} =
             Runner.execute(ctx.session, [operation], %{
               "turn_message_id" => second_user_message.id
             })

    events =
      Repo.all(
        from event in ChatEvent,
          where:
            event.chat_session_id == ^ctx.session.id and
              event.event_type == "chat_direct_tracker_operation.completed" and
              fragment(
                "?->>? = ?",
                event.public_payload,
                "tool_call_id",
                "call_reused_by_provider"
              )
      )

    assert length(events) == 2

    assert Enum.map(events, & &1.public_payload["turn_message_id"]) |> Enum.sort() ==
             Enum.sort([ctx.user_message.id, second_user_message.id])
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
