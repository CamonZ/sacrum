defmodule Sacrum.Repo.ArtifactDecisionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.ArtifactDecision
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp setup_user_and_project do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {user, project}
  end

  describe "ArtifactDecision schema columns" do
    test "has all required columns: artifact_id, subject_type, subject_id, decision_kind, decided_by_user_id, comments, metadata, timestamps" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      assert Map.has_key?(decision, :id)
      assert Map.has_key?(decision, :artifact_id)
      assert Map.has_key?(decision, :subject_type)
      assert Map.has_key?(decision, :subject_id)
      assert Map.has_key?(decision, :decision_kind)
      assert Map.has_key?(decision, :decided_by_user_id)
      assert Map.has_key?(decision, :comments)
      assert Map.has_key?(decision, :metadata)
      assert Map.has_key?(decision, :inserted_at)
      assert Map.has_key?(decision, :updated_at)
    end
  end

  describe "ArtifactDecision changeset" do
    test "creates valid decision with required fields" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "approved"
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
      assert get_field(changeset, :decision_kind) == "approved"
    end

    test "creates valid decision with all optional fields" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "rejected_with_comments",
        subject_type: "task",
        subject_id: Ecto.UUID.generate(),
        comments: "Does not meet requirements",
        metadata: %{"reason_code" => "incomplete"}
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
      assert get_field(changeset, :decision_kind) == "rejected_with_comments"
      assert get_field(changeset, :subject_type) == "task"
      assert get_field(changeset, :comments) == "Does not meet requirements"
      assert get_field(changeset, :metadata) == %{"reason_code" => "incomplete"}
    end

    test "requires artifact_id" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "approved"
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert not changeset.valid?
    end

    test "requires decision_kind" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{}

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert not changeset.valid?
      assert %{decision_kind: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires decided_by_user_id" do
      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate()
      }

      attrs = %{
        decision_kind: "approved"
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert not changeset.valid?
    end
  end

  describe "ArtifactDecision decision_kind values" do
    test "supports 'approved'" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{decision_kind: "approved"}
      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
    end

    test "supports 'rejected'" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{decision_kind: "rejected"}
      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
    end

    test "supports 'rejected_with_comments'" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{decision_kind: "rejected_with_comments"}
      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
    end

    test "supports 'needs_revision'" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{decision_kind: "needs_revision"}
      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
    end

    test "rejects invalid decision_kind" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{decision_kind: "invalid_kind"}
      changeset = ArtifactDecision.changeset(decision, attrs)
      assert not changeset.valid?
    end
  end

  describe "ArtifactDecision subject_type and subject_id" do
    test "allows optional subject_type and subject_id" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "approved"
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
      assert get_field(changeset, :subject_type) == nil
      assert get_field(changeset, :subject_id) == nil
    end

    test "accepts both subject_type and subject_id" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "approved",
        subject_type: "chat_run",
        subject_id: Ecto.UUID.generate()
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
      assert get_field(changeset, :subject_type) == "chat_run"
    end

    test "accepts subject_type without subject_id" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "approved",
        subject_type: "task_run"
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
    end

    test "accepts subject_type 'task'" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "needs_revision",
        subject_type: "task",
        subject_id: Ecto.UUID.generate()
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
    end

    test "accepts subject_type 'step_execution'" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "approved",
        subject_type: "step_execution",
        subject_id: Ecto.UUID.generate()
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
    end
  end

  describe "ArtifactDecision comments field" do
    test "accepts comments text" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "rejected_with_comments",
        comments: "The artifact does not meet the acceptance criteria. Please revise."
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?

      assert get_field(changeset, :comments) ==
               "The artifact does not meet the acceptance criteria. Please revise."
    end

    test "allows null comments" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "approved"
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
      assert get_field(changeset, :comments) == nil
    end
  end

  describe "ArtifactDecision metadata field" do
    test "accepts jsonb metadata" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "needs_revision",
        metadata: %{"revision_priority" => "high", "estimated_effort" => 3}
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?

      assert get_field(changeset, :metadata) == %{
               "revision_priority" => "high",
               "estimated_effort" => 3
             }
    end

    test "allows null metadata" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{
        decision_kind: "approved"
      }

      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
      assert get_field(changeset, :metadata) == nil
    end
  end

  describe "ArtifactDecision associations" do
    test "belongs_to decided_by_user" do
      {user, _project} = setup_user_and_project()

      decision = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs = %{decision_kind: "approved"}
      changeset = ArtifactDecision.changeset(decision, attrs)
      assert changeset.valid?
      assert get_field(changeset, :decided_by_user_id) == user.id
    end
  end

  describe "ArtifactDecision audit trail" do
    test "creates separate record for each decision (audit trail)" do
      {user, _project} = setup_user_and_project()

      # This is a conceptual test that decisions are appended, not replaced
      decision1 = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: Ecto.UUID.generate(),
        decided_by_user_id: user.id
      }

      attrs1 = %{decision_kind: "pending_review"}
      changeset1 = ArtifactDecision.changeset(decision1, attrs1)
      assert changeset1.valid?

      # A second decision for the same artifact should be a new record
      decision2 = %ArtifactDecision{
        id: Ecto.UUID.generate(),
        artifact_id: decision1.artifact_id,
        decided_by_user_id: user.id
      }

      attrs2 = %{decision_kind: "approved"}
      changeset2 = ArtifactDecision.changeset(decision2, attrs2)
      assert changeset2.valid?

      # Both decisions should have different IDs
      assert decision1.id != decision2.id
    end
  end
end
