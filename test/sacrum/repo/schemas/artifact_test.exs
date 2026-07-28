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
        filename: "draft-task.md",
        body: "# Draft task\n\nTask body"
      },
      attrs
    )
  end

  describe "create_changeset/2" do
    test "requires ownership, filename, and body" do
      changeset = Artifact.create_changeset(struct(Artifact), %{})

      assert %{
               project_id: ["can't be blank"],
               user_id: ["can't be blank"],
               filename: ["can't be blank"],
               body: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "accepts Markdown and JSON filename/body artifacts" do
      markdown_changeset = Artifact.create_changeset(artifact(), valid_attrs(%{}))

      json_changeset =
        Artifact.create_changeset(
          artifact(),
          valid_attrs(%{filename: "result.json", body: ~s({"status":"ok"})})
        )

      assert markdown_changeset.valid?
      assert json_changeset.valid?
      assert get_change(markdown_changeset, :filename) == "draft-task.md"
      assert get_change(json_changeset, :body) == ~s({"status":"ok"})
    end

    test "rejects filenames longer than the database column allows" do
      changeset =
        Artifact.create_changeset(
          artifact(),
          valid_attrs(%{filename: String.duplicate("a", 256)})
        )

      assert %{filename: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "does not cast ownership or removed lifecycle fields" do
      replacement_project_id = Ecto.UUID.generate()
      replacement_user_id = Ecto.UUID.generate()

      changeset =
        Artifact.create_changeset(
          artifact(),
          valid_attrs(%{
            project_id: replacement_project_id,
            user_id: replacement_user_id,
            artifact_state: "approved",
            visibility: "public",
            redaction_state: "not_needed",
            data: %{"ignored" => true}
          })
        )

      refute Map.has_key?(changeset.changes, :project_id)
      refute Map.has_key?(changeset.changes, :user_id)
      refute Map.has_key?(changeset.changes, :artifact_state)
      refute Map.has_key?(changeset.changes, :visibility)
      refute Map.has_key?(changeset.changes, :redaction_state)
      refute Map.has_key?(changeset.changes, :data)
    end
  end

  describe "update_changeset/2" do
    test "rejects filenames longer than the database column allows" do
      changeset =
        Artifact.update_changeset(artifact(), %{filename: String.duplicate("a", 256)})

      assert %{filename: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end
  end
end
