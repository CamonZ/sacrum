defmodule Sacrum.Repo.Schemas.ArtifactLinkTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.ArtifactLink

  defp artifact_link do
    struct(ArtifactLink, %{
      artifact_id: Ecto.UUID.generate(),
      subject_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate()
    })
  end

  defp valid_attrs(attrs) do
    Map.merge(
      %{
        subject_type: "task",
        metadata: metadata_envelope()
      },
      attrs
    )
  end

  defp metadata_envelope(overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "content_kind" => "conversation",
        "format" => "jsonl",
        "origin" => "harness",
        "presentation" => "raw",
        "extensions" => %{"harness" => %{"conversation_id" => "conv-123"}}
      },
      overrides
    )
  end

  describe "create_changeset/2" do
    test "requires artifact, subject, relationship, and ownership fields" do
      changeset = ArtifactLink.create_changeset(struct(ArtifactLink), %{})

      assert %{
               artifact_id: ["can't be blank"],
               subject_type: ["can't be blank"],
               subject_id: ["can't be blank"],
               project_id: ["can't be blank"],
               user_id: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "accepts supported subject values" do
      for subject_type <- [
            "project",
            "task",
            "task_section",
            "workflow",
            "task_run",
            "step_execution"
          ] do
        changeset =
          artifact_link()
          |> ArtifactLink.create_changeset(
            valid_attrs(%{
              subject_type: subject_type
            })
          )

        assert changeset.valid?, "expected #{inspect(subject_type)} to be valid"
      end
    end

    test "accepts an optional logical name and rejects blank names" do
      valid_changeset =
        artifact_link()
        |> ArtifactLink.create_changeset(valid_attrs(%{logical_name: "implementation_plan"}))

      assert valid_changeset.valid?

      blank_changeset =
        artifact_link()
        |> ArtifactLink.create_changeset(valid_attrs(%{logical_name: "   "}))

      assert %{logical_name: ["can't be blank"]} = errors_on(blank_changeset)
    end

    test "accepts a versioned metadata envelope and preserves provider extensions" do
      metadata =
        metadata_envelope(%{
          "origin" => "future-harness",
          "presentation" => "future-renderer",
          "extensions" => %{"future-harness" => %{"trace_id" => "trace-123"}}
        })

      changeset =
        artifact_link()
        |> ArtifactLink.create_changeset(valid_attrs(%{metadata: metadata}))

      assert changeset.valid?

      assert %{
               version: 1,
               content_kind: "conversation",
               format: "jsonl",
               origin: "future-harness",
               presentation: "future-renderer",
               extensions: %{"future-harness" => %{"trace_id" => "trace-123"}}
             } = Ecto.Changeset.get_field(changeset, :metadata)
    end

    test "rejects malformed known metadata envelope fields" do
      for metadata <- [
            %{"label" => "implementation evidence"},
            Map.delete(metadata_envelope(), "format"),
            metadata_envelope(%{"version" => 2}),
            metadata_envelope(%{"origin" => " "}),
            metadata_envelope(%{"presentation" => %{}}),
            metadata_envelope(%{"extensions" => "harness"})
          ] do
        changeset =
          artifact_link()
          |> ArtifactLink.create_changeset(valid_attrs(%{metadata: metadata}))

        assert %{metadata: metadata_errors} = errors_on(changeset)
        assert is_map(metadata_errors)
      end
    end

    test "rejects values outside the artifact link persistence contract" do
      changeset =
        artifact_link()
        |> ArtifactLink.create_changeset(
          valid_attrs(%{
            subject_type: "workflow_step"
          })
        )

      assert %{subject_type: ["is invalid"]} = errors_on(changeset)
    end
  end
end
