defmodule Sacrum.Accounts.AuthoringChatLoopDedupTest do
  @moduledoc """
  Regression for the start_authoring re-fire failure mode (ticket
  1074c44c-e3c5-4d8a-b1fc-c33b83a69986).

  When the model re-emits start_authoring for an already-active
  state_machine_id (e.g. before it learns to switch to revise_authoring),
  `AuthoringChatLoop.apply_inference_result/2` re-renders the same starter
  template and overlays it on the existing draft. The append-field merge
  must dedupe so the draft stays idempotent in the input-equal case rather
  than accumulating duplicate assumptions / open_questions / proposed_approach
  / candidate_work_units entries.

  Each call carries a distinct source_message_id so the
  `AuthoringDrafts.already_applied?/2` short-circuit (same source + same
  current_state ⇒ skip merge) does not bypass the merge under test.
  """

  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{AuthoringChatLoop, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.Users

  defp setup_session do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "authoring-dedup-#{suffix}@example.com",
        username: "authoring_dedup_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user.id, %{name: "Authoring Dedup Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})
    %{user: user, project: project, session: session}
  end

  defp inference_result(intent) do
    %Result{
      content: "Drafting authoring intent.",
      content_format: :markdown,
      public_metadata: %{"provider" => "fake", "model" => "test"},
      internal_metadata: %{"authoring_tool_intent" => intent}
    }
  end

  test "two consecutive start_authoring intents leave append fields at their unique-entry count" do
    insert_feature_exploration_template!()
    %{user: user, project: project, session: session} = setup_session()

    overrides = %{
      "open_questions" => ["Which dashboard user path should we support first?"]
    }

    # The two user turns carry the same intent payload but distinct
    # source_message_ids, so `already_applied?` returns false on the second
    # call and `merge_append_fields` actually runs.
    first_result = inference_result(feature_start_intent("msg-user-1", overrides))
    second_result = inference_result(feature_start_intent("msg-user-2", overrides))

    assert :ok = AuthoringChatLoop.apply_inference_result(session, first_result)

    assert [first_draft] = authoring_drafts_for_session(user, project, session)
    assert first_draft.data["state_machine_id"] == "feature_exploration"

    baseline_assumptions = first_draft.data["assumptions"]
    baseline_open_questions = first_draft.data["open_questions"]
    baseline_proposed_approach = first_draft.data["proposed_approach"]
    baseline_candidate_work_units = first_draft.data["candidate_work_units"]

    # Sanity: the starter template populated each append field.
    assert is_list(baseline_assumptions) and baseline_assumptions != []
    assert is_list(baseline_open_questions) and baseline_open_questions != []
    assert is_list(baseline_proposed_approach) and baseline_proposed_approach != []
    assert is_list(baseline_candidate_work_units) and baseline_candidate_work_units != []

    assert :ok = AuthoringChatLoop.apply_inference_result(session, second_result)

    assert [second_draft] = authoring_drafts_for_session(user, project, session)
    assert second_draft.id == first_draft.id

    # Cardinalities must match the first pass exactly — no doubling.
    assert length(second_draft.data["assumptions"]) == length(baseline_assumptions)
    assert length(second_draft.data["open_questions"]) == length(baseline_open_questions)

    assert length(second_draft.data["proposed_approach"]) ==
             length(baseline_proposed_approach)

    assert length(second_draft.data["candidate_work_units"]) ==
             length(baseline_candidate_work_units)

    # And the lists must be exactly equal (insertion order preserved, first
    # occurrence wins).
    assert second_draft.data["assumptions"] == baseline_assumptions
    assert second_draft.data["open_questions"] == baseline_open_questions
    assert second_draft.data["proposed_approach"] == baseline_proposed_approach
    assert second_draft.data["candidate_work_units"] == baseline_candidate_work_units
  end
end
