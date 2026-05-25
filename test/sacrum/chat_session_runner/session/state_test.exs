defmodule Sacrum.ChatSessionRunner.Session.StateTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts.ChatSessions
  alias Sacrum.ChatSessionRunner.Session.State
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "fetches sessions and preserves terminal runnable semantics", ctx do
    assert {:ok, fetched} = State.fetch_session(ctx.session.id)
    assert fetched.id == ctx.session.id
    assert {:continue, ^fetched} = State.ensure_runnable(fetched)

    {:ok, cancelled} =
      ChatSessions.transition_status(ctx.user.id, ctx.project.id, ctx.session.id, :cancelled)

    assert {:halt, ^cancelled, {:terminal_status, :cancelled}} =
             State.ensure_runnable(cancelled)
  end

  test "surfaces failure with failed status and runner checkpoint", ctx do
    assert :ok = State.surface_failure(ctx.session.id, {:boom, "private"})

    {:ok, failed} = State.fetch_session(ctx.session.id)
    assert failed.status == :failed

    assert ChatSessionRunnerFixtures.event_count(
             ctx.session,
             "chat_session_runner.failed.completed"
           ) == 2
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
