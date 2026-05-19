defmodule Sacrum.Repo.Schemas.ArtifactTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.Artifact

  defp artifact do
    struct(Artifact, %{
      project_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate()
    })
  end

  defp valid_attrs(attrs) do
    Map.merge(
      %{
        artifact_type: "task_draft",
        artifact_state: "draft",
        visibility: "public",
        redaction_state: "not_needed",
        title: "Draft task",
        content: "Task body",
        data: %{"title" => "Draft task"}
      },
      attrs
    )
  end

  describe "create_changeset/2" do
    test "requires ownership and artifact contract fields" do
      changeset = Artifact.create_changeset(struct(Artifact), %{})

      assert %{
               project_id: ["can't be blank"],
               user_id: ["can't be blank"],
               artifact_type: ["can't be blank"],
               artifact_state: ["can't be blank"],
               visibility: ["can't be blank"],
               redaction_state: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "accepts documented lifecycle, visibility, and redaction values" do
      for artifact_state <- ["draft", "pending_approval", "approved", "applied", "rejected"],
          visibility <- ["public", "internal"],
          redaction_state <- ["not_needed", "redacted", "blocked"] do
        changeset =
          artifact()
          |> Artifact.create_changeset(
            valid_attrs(%{
              artifact_state: artifact_state,
              visibility: visibility,
              redaction_state: redaction_state
            })
          )

        assert changeset.valid?,
               "expected #{inspect({artifact_state, visibility, redaction_state})} to be valid"
      end
    end

    test "rejects values outside the artifact persistence contract" do
      changeset =
        artifact()
        |> Artifact.create_changeset(
          valid_attrs(%{
            artifact_state: "published",
            visibility: "private",
            redaction_state: "unsafe"
          })
        )

      assert %{
               artifact_state: ["is invalid"],
               visibility: ["is invalid"],
               redaction_state: ["is invalid"]
             } = errors_on(changeset)
    end
  end
end
