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

    test "active draft block instructs the model to call revise_authoring with the draft id" do
      artifact = %Artifact{
        data: %{
          "state_machine_id" => "feature_exploration",
          "current_state" => "collect_feature_scope",
          "revision" => %{"source" => "authoring_template", "value" => 1},
          "open_questions" => ["What is the smallest user-visible outcome?"],
          "revision_notes" => []
        }
      }

      prompt = AuthoringSystemPrompt.build(%{active_draft: artifact})

      assert prompt =~ "revise_authoring"
      assert prompt =~ "feature_exploration"

      # The instruction line must mention both revise_authoring and the
      # draft's state_machine_id together so the model cannot misread it.
      [instruction_line] =
        prompt
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "revise_authoring"))
        |> Enum.filter(&String.contains?(&1, "feature_exploration"))
        |> Enum.take(1)

      assert instruction_line =~ "revise_authoring"
      assert instruction_line =~ "feature_exploration"
    end

    test "no-active-draft prompt does not render the revise_authoring instruction line" do
      prompt = AuthoringSystemPrompt.build()

      # The behavior rules legitimately mention revise_authoring, but the
      # Active Draft block's instruction sentence must not render when no
      # draft is present. Inspect the Active Draft section only.
      [_static, active_draft_section] = String.split(prompt, "## Active Draft", parts: 2)

      refute active_draft_section =~ "revise_authoring"
    end

    test "malformed draft (missing state_machine_id) suppresses the revise_authoring instruction" do
      artifact = %Artifact{
        data: %{
          "current_state" => "collect_feature_scope",
          "revision" => %{"source" => "authoring_template", "value" => 1}
        }
      }

      prompt = AuthoringSystemPrompt.build(%{active_draft: artifact})
      [_static, active_draft_section] = String.split(prompt, "## Active Draft", parts: 2)

      # The model must not be told to call revise_authoring with the literal
      # string "(missing)" as a state_machine_id.
      refute active_draft_section =~ "state_machine_id=(missing)"
      refute active_draft_section =~ "Call revise_authoring"
      assert active_draft_section =~ "missing its state_machine_id"
      assert active_draft_section =~ "Ask the user"
      assert active_draft_section =~ "which run they want to continue"
    end

    test "active draft block allows starting a different run kind alongside an existing draft" do
      artifact = %Artifact{
        data: %{
          "state_machine_id" => "feature_exploration",
          "current_state" => "collect_feature_scope",
          "revision" => %{"source" => "authoring_template", "value" => 1}
        }
      }

      prompt = AuthoringSystemPrompt.build(%{active_draft: artifact})

      # The instruction must scope the no-re-issue rule to the same
      # state_machine_id so multi-run sessions remain possible.
      assert prompt =~ "same state_machine_id"
      assert prompt =~ "different run kind"
    end
  end
end
