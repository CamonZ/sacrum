defmodule Sacrum.Accounts.CodeFactorySeededAuthoringFlowTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts.LiveChat
  alias Sacrum.TestSupport.AuthoringIntentProvider

  setup do
    seeded_authoring_session!("code-factory-seeded", "Seeded Code Factory")
  end

  test "starts a seeded code-factory draft composed from workflow recipes and prompt templates",
       %{user: user, project: project, session: session} do
    assert {:ok, user_message} =
             LiveChat.send_message(user.id, project.id, session.id, %{
               content:
                 "Create a code factory workflow for implementation, review, and shipping.",
               client_message_id: "client-code-factory-seeded-1"
             })

    assert {:ok, assistant_message} =
             LiveChat.run_inference(user.id, project.id, session.id,
               provider: AuthoringIntentProvider,
               test_pid: self(),
               content: "I started a Code Factory draft. Which handoff should routes carry?",
               authoring_tool_intent:
                 code_factory_start_intent(user_message.id, %{"template_kind" => "starter_draft"})
             )

    assert_receive {:authoring_provider_messages, _messages}

    assert assistant_message.metadata == %{
             "model" => "authoring-intent-model",
             "provider" => "fake"
           }

    assert [draft] = authoring_drafts_for_session(user, project, session)
    assert draft.artifact_type == "authoring_draft"
    assert draft.data["state_machine_id"] == "code_factory_creation"
    assert draft.data["state_machine_entrypoint"] == "start_code_factory_creation"
    assert draft.data["current_state"] == "collect_workflow_goal"
    assert draft.data["revision"] == %{"source" => "authoring_template", "value" => 1}
    assert draft.data["source_chat"]["source_message_id"] == user_message.id
    assert draft.data["template"]["name"] == "code_factory_creation"
    assert draft.data["trigger"] == %{"tool" => "workflow.create_from_recipe"}

    assert %{
             "workflows" => workflows,
             "transitions" => transitions,
             "validation_expectations" => validation_expectations
           } = draft.data

    assert Enum.map(workflows, & &1["key"]) == [
             "backlog",
             "implementation",
             "verification",
             "ship",
             "done"
           ]

    implementation = workflow_by_key(workflows, "implementation")

    assert Enum.map(implementation["steps"], & &1["key"]) == [
             "scaffold",
             "implement",
             "eval",
             "route"
           ]

    implement_step = step_by_key(implementation["steps"], "implement")
    eval_step = step_by_key(implementation["steps"], "eval")
    route_step = step_by_key(implementation["steps"], "route")

    assert implement_step["prompt"] =~ "{% if task.desired_behavior %}"
    assert implement_step["prompt"] =~ "{{ task.desired_behavior }}"
    refute implement_step["prompt"] =~ "{{ ticket."

    assert eval_step["output_schema"] == %{"type" => "object"}
    assert eval_step["prompt"] =~ "{% if workflow.output_schema %}"
    assert eval_step["prompt"] =~ "{{ workflow.output_schema }}"

    assert route_step["output_schema"]["properties"]["transition_to"]
    assert route_step["prompt"] =~ "{% if workflow.output_schema %}"
    assert route_step["prompt"] =~ "{{ workflow.output_schema }}"
    assert route_step["transitions_to"] == ["implementation.implement"]

    assert Enum.any?(transitions, &(&1["target_step"] == "verification.review"))
    assert Enum.any?(transitions, &(&1["target_step"] == "implementation.implement"))
    assert Enum.any?(validation_expectations, &String.contains?(&1, "auto_advance"))
    assert Enum.any?(validation_expectations, &String.contains?(&1, "schema-constrained"))

    refute Map.has_key?(assistant_message.metadata, "authoring_template")
    refute inspect(assistant_message.metadata) =~ "workflow.output_schema"
  end
end
