defmodule Sacrum.Accounts.WorkBreakdownSeededAuthoringFlowTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts.LiveChat
  alias Sacrum.TestSupport.AuthoringIntentProvider

  @required_section_keys ["desired_behavior", "testing_criteria"]

  setup do
    seeded_authoring_session!("work-breakdown-seeded", "Seeded Work Breakdown")
  end

  test "starts a seeded work-breakdown draft with internal templates and validation expectations",
       %{user: user, project: project, session: session} do
    assert {:ok, user_message} =
             LiveChat.send_message(user.id, project.id, session.id, %{
               content: "Break this parent ticket into child tasks.",
               client_message_id: "client-work-breakdown-seeded-1"
             })

    assert {:ok, assistant_message} =
             LiveChat.run_inference(user.id, project.id, session.id,
               provider: AuthoringIntentProvider,
               test_pid: self(),
               content: "I started a work-breakdown draft. Which behavior must ship first?",
               authoring_tool_intent: work_breakdown_start_intent(user_message.id)
             )

    assert_receive {:authoring_provider_messages, _messages}

    assert assistant_message.metadata == %{
             "model" => "authoring-intent-model",
             "provider" => "fake"
           }

    assert [draft] = authoring_drafts_for_session(user, project, session)
    assert draft.artifact_type == "authoring_draft"
    assert draft.data["state_machine_id"] == "work_breakdown_authoring"
    assert draft.data["state_machine_entrypoint"] == "start_work_breakdown_authoring"
    assert draft.data["current_state"] == "collect_parent_scope"
    assert draft.data["revision"] == %{"source" => "authoring_template", "value" => 1}
    assert draft.data["source_chat"]["source_message_id"] == user_message.id
    assert draft.data["apply_target"] == "task_tree"

    assert Enum.map(draft.data["required_section_templates"], & &1["key"]) ==
             @required_section_keys

    assert Enum.map(draft.data["required_sections"], & &1["key"]) == @required_section_keys

    assert Enum.any?(
             draft.data["validation_expectations"],
             &String.contains?(&1, "desired behavior")
           )

    assert Enum.any?(
             draft.data["validation_expectations"],
             &String.contains?(&1, "testing criteria")
           )

    refute Map.has_key?(draft.data, "starter_shape")
    refute Map.has_key?(assistant_message.metadata, "authoring_template")
    refute inspect(assistant_message.metadata) =~ "required_section_templates"
    refute inspect(assistant_message.metadata) =~ "validation_expectations"
  end
end
