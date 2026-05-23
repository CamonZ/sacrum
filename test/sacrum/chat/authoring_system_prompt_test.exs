defmodule Sacrum.Chat.AuthoringSystemPromptTest do
  use ExUnit.Case, async: true

  alias Sacrum.Chat.AuthoringSystemPrompt
  alias Sacrum.Repo.Schemas.Artifact

  describe "build/1" do
    test "renders 'Vertebrae' and never renders 'Sacrum'" do
      prompt = AuthoringSystemPrompt.build()

      assert prompt =~ "Vertebrae"
      refute String.contains?(prompt, "Sacrum")
    end

    test "lists each authoring run-kind catalog entry" do
      prompt = AuthoringSystemPrompt.build()

      for run_kind <- [
            "feature_exploration",
            "work_breakdown",
            "code_factory",
            "investigation_session"
          ] do
        assert prompt =~ run_kind
      end
    end

    test "reports 'no active draft' when no Artifact is provided" do
      prompt = AuthoringSystemPrompt.build()

      assert prompt =~ "no active draft"
    end

    test "reports the active draft's state_machine_id, current_state, revision and questions" do
      artifact = %Artifact{
        data: %{
          "state_machine_id" => "feature_exploration",
          "current_state" => "collect_feature_scope",
          "revision" => %{"source" => "authoring_template", "value" => 1},
          "open_questions" => ["What is the smallest user-visible outcome?"],
          "revision_notes" => ["Tighten scope to one user flow."]
        }
      }

      prompt = AuthoringSystemPrompt.build(%{active_draft: artifact})

      assert prompt =~ "state_machine_id: feature_exploration"
      assert prompt =~ "current_state: collect_feature_scope"
      assert prompt =~ "revision: authoring_template:1"
      assert prompt =~ "What is the smallest user-visible outcome?"
      assert prompt =~ "Tighten scope to one user flow."
    end

    test "includes a maturity hint after multiple user turns with no active draft" do
      prompt = AuthoringSystemPrompt.build(%{user_turn_count: 3})

      assert prompt =~ "3 turns"
      assert prompt =~ "onsider whether you have enough"
    end

    test "lists explicit trigger heuristics in the behavior rules" do
      prompt = AuthoringSystemPrompt.build()

      assert prompt =~ "help me design"
      assert prompt =~ "break this into tasks"
      assert prompt =~ "investigate why"
      assert prompt =~ "create a workflow for"
    end
  end
end
