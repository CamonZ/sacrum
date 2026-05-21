defmodule Sacrum.Accounts.AuthoringDraftsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.AuthoringDrafts
  alias Sacrum.Accounts.ChatSessions
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Users

  defp create_user(prefix \\ "authoring-draft") do
    suffix = System.unique_integer([:positive])
    username_prefix = String.replace(prefix, "-", "_")

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{username_prefix}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name \\ "Authoring Draft Project") do
    {:ok, project} = Projects.insert(user.id, %{name: name})
    project
  end

  defp create_chat_session(user, project) do
    {:ok, session} =
      ChatSessions.insert(user.id, project.id, %{
        session_kind: "planning",
        engine_kind: "native_planner"
      })

    session
  end

  defp setup_chat_session(_context) do
    user = create_user()
    project = create_project(user)
    chat_session = create_chat_session(user, project)

    %{user: user, project: project, chat_session: chat_session}
  end

  describe "upsert_for_chat_session/4" do
    setup [:setup_chat_session]

    test "creates an authoring draft artifact for a chat session and state machine", %{
      user: user,
      project: project,
      chat_session: chat_session
    } do
      patch = %{
        state_machine_id: "feature_authoring",
        state_machine_entrypoint: "start_work_breakdown_authoring",
        current_state: "collect_scope",
        revision: 1,
        source_chat: %{
          chat_session_id: chat_session.id,
          source_message_id: "msg_user_001",
          turn_index: 3
        },
        assumptions: [
          "The feature belongs in the current project.",
          "The work should preserve existing workflow boundaries."
        ],
        open_questions: [
          "Which user path must be supported first?"
        ],
        proposed_approach: [
          "Create a focused backend service.",
          "Persist a draft artifact before validation."
        ],
        candidate_work_units: [
          %{
            "title" => "Persist authoring draft artifacts",
            "level" => "ticket",
            "desired_behavior" =>
              "State-machine authoring output is saved as a reusable artifact."
          }
        ],
        apply_targets: [
          %{"kind" => "task_tree", "mode" => "create_children"}
        ]
      }

      assert {:ok, %{artifact: artifact, link: link}} =
               AuthoringDrafts.upsert_for_chat_session(
                 user.id,
                 project.id,
                 chat_session.id,
                 patch
               )

      reloaded_artifact = Repo.get!(Artifact, artifact.id)

      assert reloaded_artifact.user_id == user.id
      assert reloaded_artifact.project_id == project.id
      assert reloaded_artifact.artifact_type == "authoring_draft"
      assert reloaded_artifact.artifact_state == "draft"
      assert reloaded_artifact.visibility == "public"
      assert reloaded_artifact.redaction_state == "not_needed"
      assert reloaded_artifact.title == "feature_authoring authoring draft"

      assert reloaded_artifact.data == %{
               "state_machine_id" => "feature_authoring",
               "state_machine_entrypoint" => "start_work_breakdown_authoring",
               "current_state" => "collect_scope",
               "revision" => 1,
               "source_chat" => %{
                 "chat_session_id" => chat_session.id,
                 "source_message_id" => "msg_user_001",
                 "turn_index" => 3
               },
               "assumptions" => [
                 "The feature belongs in the current project.",
                 "The work should preserve existing workflow boundaries."
               ],
               "open_questions" => [
                 "Which user path must be supported first?"
               ],
               "proposed_approach" => [
                 "Create a focused backend service.",
                 "Persist a draft artifact before validation."
               ],
               "candidate_work_units" => [
                 %{
                   "title" => "Persist authoring draft artifacts",
                   "level" => "ticket",
                   "desired_behavior" =>
                     "State-machine authoring output is saved as a reusable artifact."
                 }
               ],
               "apply_targets" => [
                 %{"kind" => "task_tree", "mode" => "create_children"}
               ]
             }

      assert link.user_id == user.id
      assert link.project_id == project.id
      assert link.artifact_id == artifact.id
      assert link.subject_type == "chat_session"
      assert link.subject_id == chat_session.id
      assert link.relationship_kind == "produced_by"

      assert link.metadata == %{
               "provenance" => %{
                 "user_id" => user.id,
                 "project_id" => project.id,
                 "chat_session_id" => chat_session.id,
                 "source_message_id" => "msg_user_001"
               },
               "state_machine_id" => "feature_authoring",
               "current_state" => "collect_scope",
               "revision" => 1,
               "source_chat" => %{
                 "chat_session_id" => chat_session.id,
                 "source_message_id" => "msg_user_001",
                 "turn_index" => 3
               }
             }
    end

    test "updates an existing draft from structured patch data without dropping omitted fields",
         %{
           user: user,
           project: project,
           chat_session: chat_session
         } do
      assert {:ok, %{artifact: original_artifact}} =
               AuthoringDrafts.upsert_for_chat_session(
                 user.id,
                 project.id,
                 chat_session.id,
                 %{
                   state_machine_id: "feature_authoring",
                   state_machine_entrypoint: "start_work_breakdown_authoring",
                   current_state: "collect_scope",
                   revision: 1,
                   source_chat: %{
                     chat_session_id: chat_session.id,
                     source_message_id: "msg_user_001",
                     turn_index: 3
                   },
                   assumptions: ["The feature belongs in this project."],
                   open_questions: ["Which user path is first?"],
                   proposed_approach: ["Draft the backend contract."],
                   candidate_work_units: [
                     %{"title" => "Create draft service", "level" => "task"}
                   ],
                   apply_targets: [%{"kind" => "task_tree", "mode" => "create_children"}]
                 }
               )

      assert {:ok, %{artifact: updated_artifact}} =
               AuthoringDrafts.upsert_for_chat_session(
                 user.id,
                 project.id,
                 chat_session.id,
                 %{
                   state_machine_id: "feature_authoring",
                   current_state: "refine_scope",
                   revision: 2,
                   source_chat: %{
                     chat_session_id: chat_session.id,
                     source_message_id: "msg_assistant_002",
                     turn_index: 4
                   },
                   assumptions: ["The draft should remain applyable after validation."],
                   candidate_work_units: [
                     %{"title" => "Validate draft before apply", "level" => "task"}
                   ]
                 }
               )

      assert updated_artifact.id == original_artifact.id

      reloaded_artifact = Repo.get!(Artifact, updated_artifact.id)

      assert reloaded_artifact.data["state_machine_id"] == "feature_authoring"

      assert reloaded_artifact.data["state_machine_entrypoint"] ==
               "start_work_breakdown_authoring"

      assert reloaded_artifact.data["current_state"] == "refine_scope"
      assert reloaded_artifact.data["revision"] == 2

      assert reloaded_artifact.data["source_chat"] == %{
               "chat_session_id" => chat_session.id,
               "source_message_id" => "msg_assistant_002",
               "turn_index" => 4
             }

      assert reloaded_artifact.data["assumptions"] == [
               "The feature belongs in this project.",
               "The draft should remain applyable after validation."
             ]

      assert reloaded_artifact.data["open_questions"] == ["Which user path is first?"]
      assert reloaded_artifact.data["proposed_approach"] == ["Draft the backend contract."]

      assert reloaded_artifact.data["candidate_work_units"] == [
               %{"title" => "Create draft service", "level" => "task"},
               %{"title" => "Validate draft before apply", "level" => "task"}
             ]

      assert reloaded_artifact.data["apply_targets"] == [
               %{"kind" => "task_tree", "mode" => "create_children"}
             ]

      links = ArtifactLinks.list_by_artifact(user.id, project.id, updated_artifact.id)

      assert [
               %{
                 subject_type: "chat_session",
                 subject_id: subject_id,
                 relationship_kind: "produced_by",
                 metadata: metadata
               }
             ] =
               links

      assert subject_id == chat_session.id

      assert metadata == %{
               "provenance" => %{
                 "user_id" => user.id,
                 "project_id" => project.id,
                 "chat_session_id" => chat_session.id,
                 "source_message_id" => "msg_user_001"
               },
               "state_machine_id" => "feature_authoring",
               "current_state" => "refine_scope",
               "revision" => 2,
               "source_chat" => %{
                 "chat_session_id" => chat_session.id,
                 "source_message_id" => "msg_assistant_002",
                 "turn_index" => 4
               }
             }
    end

    test "returns an error when the patch is missing the state machine id", %{
      user: user,
      project: project,
      chat_session: chat_session
    } do
      assert {:error, :missing_state_machine_id} =
               AuthoringDrafts.upsert_for_chat_session(
                 user.id,
                 project.id,
                 chat_session.id,
                 %{current_state: "collect_scope"}
               )
    end
  end
end
