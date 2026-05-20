defmodule Sacrum.Repo.AuthoringTemplatesTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.AuthoringTemplates
  alias Sacrum.Repo.Schemas.AuthoringTemplate

  @classification %{
    run_kind: "goal_exploration",
    artifact_type: "workflow_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_goal_exploration"
  }

  defp valid_attrs(attrs \\ %{}) do
    @classification
    |> Map.merge(%{
      name: "default",
      payload: %{
        "sections" => [
          %{"kind" => "goal", "title" => "Goal"},
          %{"kind" => "constraints", "title" => "Constraints"}
        ],
        "validation_policy" => %{"required_sections" => ["goal"]}
      }
    })
    |> Map.merge(attrs)
  end

  defp string_key_classification do
    Map.new(@classification, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  describe "insert/1 and classification queries" do
    test "inserts, fetches, and lists app-owned templates by classification" do
      assert {:ok, template} = AuthoringTemplates.insert(valid_attrs())

      assert AuthoringTemplate == template.__struct__
      assert template.run_kind == "goal_exploration"
      assert template.artifact_type == "workflow_draft"
      assert template.template_kind == "starter_draft"
      assert template.state_machine_entrypoint == "start_goal_exploration"
      assert template.payload["validation_policy"]["required_sections"] == ["goal"]

      assert {:ok, fetched} =
               AuthoringTemplates.get_by_classification_and_name(@classification, "default")

      assert fetched.id == template.id

      assert [listed] = AuthoringTemplates.list_by_classification(Keyword.new(@classification))
      assert listed.id == template.id
    end

    test "inserts an explicit changeset" do
      changeset =
        %AuthoringTemplate{}
        |> AuthoringTemplate.create_changeset(valid_attrs())

      assert {:ok, template} = AuthoringTemplates.insert(changeset)
      assert template.name == "default"
    end

    test "lists only templates matching every supplied classification field" do
      {:ok, matching} = AuthoringTemplates.insert(valid_attrs(%{name: "matching"}))

      {:ok, _other_run_kind} =
        AuthoringTemplates.insert(
          valid_attrs(%{run_kind: "implementation", name: "implementation"})
        )

      {:ok, _other_artifact_type} =
        AuthoringTemplates.insert(valid_attrs(%{artifact_type: "task_draft", name: "task"}))

      {:ok, _other_template_kind} =
        AuthoringTemplates.insert(
          valid_attrs(%{template_kind: "prompt_template", name: "prompt"})
        )

      {:ok, _other_entrypoint} =
        AuthoringTemplates.insert(
          valid_attrs(%{state_machine_entrypoint: "resume_goal_exploration", name: "resume"})
        )

      listed =
        AuthoringTemplates.list_by_classification(string_key_classification())

      assert Enum.map(listed, & &1.id) == [matching.id]
    end

    test "requires a complete classification filter" do
      assert_raise ArgumentError,
                   "missing required classification filter run_kind",
                   fn -> AuthoringTemplates.get_by_classification_and_name(%{}, "default") end

      assert_raise ArgumentError,
                   "missing required classification filter state_machine_entrypoint",
                   fn ->
                     AuthoringTemplates.list_by_classification(
                       run_kind: "goal_exploration",
                       artifact_type: "workflow_draft",
                       template_kind: "starter_draft"
                     )
                   end
    end

    test "requires map or keyword classification filters" do
      assert_raise ArgumentError,
                   "classification filters must be a map or keyword list",
                   fn -> AuthoringTemplates.list_by_classification([:run_kind]) end
    end
  end

  describe "changeset validation" do
    test "rejects missing required classification fields" do
      attrs =
        valid_attrs()
        |> Map.drop([
          :run_kind,
          :artifact_type,
          :template_kind,
          :state_machine_entrypoint,
          :name
        ])

      assert {:error, changeset} = AuthoringTemplates.insert(attrs)

      assert %{
               run_kind: ["can't be blank"],
               artifact_type: ["can't be blank"],
               template_kind: ["can't be blank"],
               state_machine_entrypoint: ["can't be blank"],
               name: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "rejects unsupported template kinds without persisting" do
      assert {:error, changeset} =
               AuthoringTemplates.insert(valid_attrs(%{template_kind: "general_rule_engine"}))

      assert %{template_kind: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects malformed structured payloads without persisting" do
      assert {:error, changeset} = AuthoringTemplates.insert(valid_attrs(%{payload: "markdown"}))

      assert %{payload: ["is invalid"]} = errors_on(changeset)

      assert {:error, empty_payload_changeset} =
               AuthoringTemplates.insert(valid_attrs(%{payload: %{}}))

      assert %{payload: ["must be a non-empty map"]} = errors_on(empty_payload_changeset)
    end
  end
end
