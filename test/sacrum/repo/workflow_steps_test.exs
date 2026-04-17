defmodule Sacrum.Repo.WorkflowStepsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.WorkflowStep

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  @valid_attrs %{
    name: "Review",
    goal: "Review the implementation",
    agents: ["reviewer"],
    skills: ["code-review"],
    agent_config: %{"timeout" => 300},
    step_order: 1
  }

  defp create_workflow do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "My Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Default"})
    workflow
  end

  describe "insert/2" do
    test "creates step with valid attrs" do
      workflow = create_workflow()
      assert {:ok, %WorkflowStep{} = step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert step.name == "Review"
      assert step.goal == "Review the implementation"
      assert step.agents == ["reviewer"]
      assert step.skills == ["code-review"]
      assert step.agent_config == %{"timeout" => 300}
      assert step.step_order == 1
      assert step.is_final == false
      assert step.workflow_id == workflow.id
    end

    test "accepts workflow_id as binary" do
      workflow = create_workflow()

      assert {:ok, %WorkflowStep{}} =
               WorkflowSteps.insert(
                 workflow.id,
                 workflow.project_id,
                 workflow.user_id,
                 @valid_attrs
               )
    end

    test "defaults step_type to execute" do
      workflow = create_workflow()
      assert {:ok, %WorkflowStep{} = step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert step.step_type == "execute"
    end

    test "creates step with explicit step_type" do
      workflow = create_workflow()

      for type <- ~w(execute evaluate route) do
        attrs = Map.put(@valid_attrs, :step_type, type)
        assert {:ok, %WorkflowStep{} = step} = WorkflowSteps.insert(workflow, attrs)
        assert step.step_type == type
      end
    end

    test "rejects invalid step_type" do
      workflow = create_workflow()
      attrs = Map.put(@valid_attrs, :step_type, "invalid")
      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{step_type: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects missing name" do
      workflow = create_workflow()
      assert {:error, changeset} = WorkflowSteps.insert(workflow, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "all/1" do
    test "returns steps for a workflow ordered by step_order" do
      workflow = create_workflow()
      {:ok, s2} = WorkflowSteps.insert(workflow, %{name: "Second", step_order: 2})
      {:ok, s1} = WorkflowSteps.insert(workflow, %{name: "First", step_order: 1})

      steps =
        WorkflowSteps.all(
          conditions: [workflow_id: workflow.id],
          order_by: [asc: :step_order, asc: :inserted_at]
        )

      assert length(steps) == 2
      assert Enum.map(steps, & &1.id) == [s1.id, s2.id]
    end

    test "returns empty list when workflow has no steps" do
      workflow = create_workflow()

      assert [] =
               WorkflowSteps.all(
                 conditions: [workflow_id: workflow.id],
                 order_by: [asc: :step_order, asc: :inserted_at]
               )
    end
  end

  describe "get/1" do
    test "returns step by ID" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert {:ok, found} = WorkflowSteps.get(step.id)
      assert found.id == step.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = WorkflowSteps.get(Ecto.UUID.generate())
    end
  end

  describe "update/2" do
    test "updates step fields" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)

      assert {:ok, updated} =
               WorkflowSteps.update(step, %{name: "Updated", goal: "New goal", is_final: true})

      assert updated.name == "Updated"
      assert updated.goal == "New goal"
      assert updated.is_final == true
    end

    test "updates step_type" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert step.step_type == "execute"

      assert {:ok, updated} = WorkflowSteps.update(step, %{step_type: "evaluate"})
      assert updated.step_type == "evaluate"
    end

    test "rejects invalid step_type on update" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)

      assert {:error, changeset} = WorkflowSteps.update(step, %{step_type: "bogus"})
      assert %{step_type: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "delete/1" do
    test "removes the step" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert {:ok, _} = WorkflowSteps.delete(step)
      assert {:error, :not_found} = WorkflowSteps.get(step.id)
    end
  end

  describe "output_schema validation" do
    test "accepts valid JSON Schema for evaluate steps" do
      workflow = create_workflow()

      schema = %{
        "type" => "object",
        "properties" => %{
          "result" => %{"type" => "string"}
        },
        "required" => ["result"]
      }

      attrs = Map.merge(@valid_attrs, %{step_type: "evaluate", output_schema: schema})

      assert {:ok, %WorkflowStep{output_schema: returned_schema}} =
               WorkflowSteps.insert(workflow, attrs)

      assert returned_schema == schema
    end

    test "rejects non-map output_schema" do
      workflow = create_workflow()

      attrs = Map.merge(@valid_attrs, %{output_schema: "not a map"})
      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{output_schema: ["is invalid"]} = errors_on(changeset)
    end

    test "route steps auto-set routing contract schema on create" do
      workflow = create_workflow()

      attrs = Map.merge(@valid_attrs, %{step_type: "route"})

      assert {:ok, %WorkflowStep{step_type: "route"} = step} =
               WorkflowSteps.insert(workflow, attrs)

      expected_schema = %{
        "type" => "object",
        "properties" => %{
          "transition_to" => %{"type" => "string", "format" => "uuid"},
          "transition_type" => %{
            "type" => "string",
            "enum" => ["intra_workflow", "inter_workflow"]
          },
          "handoff" => %{"type" => "object"}
        },
        "required" => ["transition_to", "transition_type"],
        "additionalProperties" => false
      }

      assert step.output_schema == expected_schema
    end

    test "route steps reject custom output_schema that doesn't match routing contract" do
      workflow = create_workflow()

      custom_schema = %{
        "type" => "object",
        "properties" => %{
          "custom_field" => %{"type" => "string"}
        }
      }

      attrs = Map.merge(@valid_attrs, %{step_type: "route", output_schema: custom_schema})
      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)

      assert %{output_schema: [message]} = errors_on(changeset)
      assert String.contains?(message, "routing contract schema")
    end

    test "route steps accept correct routing contract schema" do
      workflow = create_workflow()

      correct_schema = %{
        "type" => "object",
        "properties" => %{
          "transition_to" => %{"type" => "string", "format" => "uuid"},
          "transition_type" => %{
            "type" => "string",
            "enum" => ["intra_workflow", "inter_workflow"]
          }
        },
        "required" => ["transition_to", "transition_type"],
        "additionalProperties" => false
      }

      attrs = Map.merge(@valid_attrs, %{step_type: "route", output_schema: correct_schema})

      assert {:ok, %WorkflowStep{output_schema: returned_schema}} =
               WorkflowSteps.insert(workflow, attrs)

      assert returned_schema == correct_schema
    end

    test "allows nil output_schema" do
      workflow = create_workflow()

      attrs = Map.merge(@valid_attrs, %{output_schema: nil})
      assert {:ok, %WorkflowStep{output_schema: nil}} = WorkflowSteps.insert(workflow, attrs)
    end

    test "preserves output_schema on update for evaluate steps" do
      workflow = create_workflow()

      schema = %{
        "type" => "object",
        "properties" => %{
          "data" => %{"type" => "string"}
        }
      }

      {:ok, step} =
        WorkflowSteps.insert(
          workflow,
          Map.merge(@valid_attrs, %{step_type: "evaluate", output_schema: schema})
        )

      updated_schema = %{
        "type" => "object",
        "properties" => %{
          "new_data" => %{"type" => "integer"}
        }
      }

      {:ok, updated} = WorkflowSteps.update(step, %{output_schema: updated_schema})
      assert updated.output_schema == updated_schema
    end

    test "route steps enforce routing contract on update" do
      workflow = create_workflow()

      {:ok, step} = WorkflowSteps.insert(workflow, Map.merge(@valid_attrs, %{step_type: "route"}))

      invalid_schema = %{
        "type" => "object",
        "properties" => %{
          "invalid" => %{"type" => "string"}
        }
      }

      assert {:error, changeset} = WorkflowSteps.update(step, %{output_schema: invalid_schema})
      assert %{output_schema: _} = errors_on(changeset)
    end

    test "route steps accept routing contract schema with optional handoff property" do
      workflow = create_workflow()

      schema_with_handoff = %{
        "type" => "object",
        "properties" => %{
          "transition_to" => %{"type" => "string", "format" => "uuid"},
          "transition_type" => %{
            "type" => "string",
            "enum" => ["intra_workflow", "inter_workflow"]
          },
          "handoff" => %{"type" => "object"}
        },
        "required" => ["transition_to", "transition_type"],
        "additionalProperties" => false
      }

      attrs = Map.merge(@valid_attrs, %{step_type: "route", output_schema: schema_with_handoff})

      assert {:ok, %WorkflowStep{output_schema: returned_schema}} =
               WorkflowSteps.insert(workflow, attrs)

      assert returned_schema == schema_with_handoff
    end

    test "route steps reject handoff property with wrong type in output schema" do
      workflow = create_workflow()

      invalid_schema = %{
        "type" => "object",
        "properties" => %{
          "transition_to" => %{"type" => "string", "format" => "uuid"},
          "transition_type" => %{
            "type" => "string",
            "enum" => ["intra_workflow", "inter_workflow"]
          },
          "handoff" => %{"type" => "string"}
        },
        "required" => ["transition_to", "transition_type"],
        "additionalProperties" => false
      }

      attrs = Map.merge(@valid_attrs, %{step_type: "route", output_schema: invalid_schema})
      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{output_schema: [message]} = errors_on(changeset)
      assert String.contains?(message, "routing contract schema")
    end

    test "route steps reject unknown properties even with handoff present" do
      workflow = create_workflow()

      invalid_schema = %{
        "type" => "object",
        "properties" => %{
          "transition_to" => %{"type" => "string", "format" => "uuid"},
          "transition_type" => %{
            "type" => "string",
            "enum" => ["intra_workflow", "inter_workflow"]
          },
          "handoff" => %{"type" => "object"},
          "unknown_field" => %{"type" => "string"}
        },
        "required" => ["transition_to", "transition_type"],
        "additionalProperties" => false
      }

      attrs = Map.merge(@valid_attrs, %{step_type: "route", output_schema: invalid_schema})
      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{output_schema: [message]} = errors_on(changeset)
      assert String.contains?(message, "routing contract schema")
    end

    test "route steps auto-set schema including handoff stays consistent on update" do
      workflow = create_workflow()

      attrs = Map.merge(@valid_attrs, %{step_type: "route"})
      {:ok, step} = WorkflowSteps.insert(workflow, attrs)

      # Route steps should have auto-set the correct schema with handoff
      expected_schema = %{
        "type" => "object",
        "properties" => %{
          "transition_to" => %{"type" => "string", "format" => "uuid"},
          "transition_type" => %{
            "type" => "string",
            "enum" => ["intra_workflow", "inter_workflow"]
          },
          "handoff" => %{"type" => "object"}
        },
        "required" => ["transition_to", "transition_type"],
        "additionalProperties" => false
      }

      assert step.output_schema == expected_schema

      # Update other fields and verify schema remains intact
      {:ok, updated} = WorkflowSteps.update(step, %{name: "Updated Route Step"})
      assert updated.output_schema == expected_schema
    end
  end
end
