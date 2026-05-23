defmodule Sacrum.Chat.AuthoringVerifierPromptTest do
  use ExUnit.Case, async: true

  alias Sacrum.Chat.AuthoringVerifierPrompt

  describe "build/3" do
    test "renders 'Vertebrae' and never renders 'Sacrum' in the prompt" do
      transcript = [%{role: "user", content: "Hello"}]
      intent = %{"action" => "start_authoring", "run_kind" => "feature_exploration"}

      prompt = AuthoringVerifierPrompt.build(transcript, intent)

      assert prompt =~ "Vertebrae"
      refute String.contains?(prompt, "Sacrum")
    end

    test "includes the proposed intent and the transcript in the prompt body" do
      transcript = [
        %{role: "user", content: "Help me design a new search box."},
        %{role: "assistant", content: "Tell me more about the target users."}
      ]

      intent = %{
        "action" => "start_authoring",
        "run_kind" => "feature_exploration",
        "state_machine_id" => "feature_exploration"
      }

      prompt = AuthoringVerifierPrompt.build(transcript, intent)

      assert prompt =~ "start_authoring"
      assert prompt =~ "feature_exploration"
      assert prompt =~ "Help me design a new search box."
      assert prompt =~ "Tell me more about the target users."
    end

    test "labels the active draft block as '(no active draft)' when nil is passed" do
      prompt = AuthoringVerifierPrompt.build([], %{"action" => "start_authoring"})

      assert prompt =~ "(no active draft)"
    end

    test "formats transcript messages with atom roles as 'role: content' lines" do
      transcript = [
        %{role: :user, content: "Atom-role line."},
        %{role: :assistant, content: "Atom-role reply."}
      ]

      prompt = AuthoringVerifierPrompt.build(transcript, %{"action" => "start_authoring"})

      assert prompt =~ "user: Atom-role line."
      assert prompt =~ "assistant: Atom-role reply."
      refute prompt =~ ":user"
      refute prompt =~ ":assistant"
    end
  end

  describe "response_format/0" do
    test "returns an OpenAI-shaped json_schema response_format envelope" do
      assert %{
               "type" => "json_schema",
               "json_schema" => %{"name" => name, "strict" => true, "schema" => schema}
             } = AuthoringVerifierPrompt.response_format()

      assert is_binary(name) and name != ""
      assert schema["type"] == "object"

      assert MapSet.new(schema["required"]) ==
               MapSet.new(["sufficient", "missing", "open_questions", "reasoning"])
    end
  end
end
