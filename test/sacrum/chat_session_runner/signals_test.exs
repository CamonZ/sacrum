defmodule Sacrum.ChatSessionRunner.SignalsTest do
  @moduledoc """
  Locks the chat-session signal vocabulary in place. Every routed action
  consumes one of these signal names, so they form a public contract between
  the AgentServer routing table and the runner pipeline.
  """

  use ExUnit.Case, async: true

  alias Sacrum.ChatSessionRunner.Signals

  describe "source/0" do
    test "namespaces every emitted CloudEvents signal under the runner" do
      assert Signals.source() == "/sacrum/chat_session_runner"
    end
  end

  describe "individual signal accessors" do
    test "use the chat-session prefix" do
      assert Signals.user_turn() == "sacrum.chat_session.user_turn"
      assert Signals.run() == "sacrum.chat_session.run"
      assert Signals.intake() == "sacrum.chat_session.intake"
      assert Signals.load_messages() == "sacrum.chat_session.load_messages"
      assert Signals.invoke_inference() == "sacrum.chat_session.invoke_inference"
      assert Signals.verify_authoring() == "sacrum.chat_session.verify_authoring"
      assert Signals.append_assistant() == "sacrum.chat_session.append_assistant"
      assert Signals.resume_assistant() == "sacrum.chat_session.resume_assistant"
      assert Signals.complete_session() == "sacrum.chat_session.complete_session"
      assert Signals.mark_failed() == "sacrum.chat_session.mark_failed"
      assert Signals.noop() == "sacrum.chat_session.noop"
    end

    test "every accessor returns a unique string" do
      values = [
        Signals.user_turn(),
        Signals.run(),
        Signals.intake(),
        Signals.load_messages(),
        Signals.invoke_inference(),
        Signals.verify_authoring(),
        Signals.append_assistant(),
        Signals.resume_assistant(),
        Signals.complete_session(),
        Signals.mark_failed(),
        Signals.noop()
      ]

      assert length(Enum.uniq(values)) == length(values)
    end
  end

  describe "all/0" do
    test "lists every routed signal" do
      assert Signals.all() == [
               Signals.user_turn(),
               Signals.run(),
               Signals.intake(),
               Signals.load_messages(),
               Signals.invoke_inference(),
               Signals.verify_authoring(),
               Signals.append_assistant(),
               Signals.resume_assistant(),
               Signals.complete_session(),
               Signals.mark_failed()
             ]
    end

    test "excludes noop because no action routes from it" do
      refute Signals.noop() in Signals.all()
    end
  end
end
