defmodule Sacrum.ChatSessionRunner.Session.FixturesTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts.Projects
  alias Sacrum.ChatSessionRunner.Session.Hydration
  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup do
    user = ChatSessionRunnerFixtures.create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Runner Fixture Project"})
    %{user: user, project: project}
  end

  test "shared fixtures build durable states for recovery-focused runner tests", ctx do
    cases = [
      {ChatSessionRunnerFixtures.pending_user_turn_fixture(ctx), :pending_user_turn,
       Signals.load_messages()},
      {ChatSessionRunnerFixtures.partial_direct_tool_continuation_fixture(ctx),
       :partially_completed_tool_turn, Signals.resume_assistant()},
      {ChatSessionRunnerFixtures.completed_turn_fixture(ctx), :completed_turn, Signals.noop()},
      {ChatSessionRunnerFixtures.failed_turn_fixture(ctx), :failed_turn, Signals.noop()}
    ]

    for {fixture, turn_state, next_signal} <- cases do
      assert {:ok, snapshot} = Hydration.hydrate_session(fixture.session.id)
      assert snapshot.turn_state == turn_state
      assert snapshot.next_signal == next_signal
      assert snapshot.turn_message_id == fixture.turn_message_id
      assert snapshot.idempotency_keys["user_client_message_id"] == fixture.user_client_message_id
    end
  end
end
