defmodule Sacrum.Repo.WorkflowStepsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.WorkflowStep

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  @valid_attrs %{
    name: "Review",
    goal: "Review the implementation",
    step_order: 1,
    config: %{
      "agents" => ["reviewer"],
      "skills" => ["code-review"],
      "agent_config" => %{"timeout" => 300}
    }
  }

  @structured_output_schema %{
    "type" => "object",
    "properties" => %{"result" => %{"type" => "string"}},
    "required" => ["result"],
    "additionalProperties" => false
  }

  defp create_workflow do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(
        Map.merge(@valid_user_attrs, %{
          email: "workflow_steps_#{suffix}@example.com",
          username: "workflow_steps_#{suffix}"
        })
      )

    {:ok, project} = Projects.insert(user, %{name: "My Project #{suffix}"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Default"})
    workflow
  end

  defp create_task(workflow, step, title) do
    %Task{
      project_id: workflow.project_id,
      user_id: workflow.user_id,
      workflow_id: workflow.id,
      current_step_id: step.id
    }
    |> Task.create_changeset(%{title: title})
    |> Repo.insert()
  end

  defp route_config(target) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "task-level",
          "when" => %{"ref" => "task.level", "op" => "eq", "value" => "task"},
          "transition" => %{"type" => "intra_workflow", "step_id" => target}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "intra_workflow", "step_id" => target}
      }
    }
  end

  describe "insert/2" do
    test "creates step with valid attrs" do
      workflow = create_workflow()
      assert {:ok, %WorkflowStep{} = step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert step.name == "Review"
      assert step.goal == "Review the implementation"
      assert step.config.agents == ["reviewer"]
      assert step.config.skills == ["code-review"]
      assert step.config.agent_config == %{"timeout" => 300}
      assert step.step_order == 1
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

    test "defaults step_type to llm_inference" do
      workflow = create_workflow()
      assert {:ok, %WorkflowStep{} = step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert step.step_type == :llm_inference
    end

    test "creates step with explicit step_type" do
      for type <- ~w(llm_inference route wait_children human_input stop finish) do
        workflow = create_workflow()
        attrs = %{name: "Step #{type}", step_type: type}

        attrs =
          if type == "route" do
            {:ok, destination} =
              WorkflowSteps.insert(workflow, %{name: "Destination", step_order: 2})

            Map.put(attrs, :config, %{"route_config" => route_config(destination.id)})
          else
            attrs
          end

        assert {:ok, %WorkflowStep{} = step} = WorkflowSteps.insert(workflow, attrs)
        assert step.step_type == String.to_existing_atom(type)
      end
    end

    test "rejects invalid step_type" do
      workflow = create_workflow()
      attrs = Map.put(@valid_attrs, :step_type, "invalid")
      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{step_type: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts finish as a promptless step and persists its string value" do
      workflow = create_workflow()

      assert {:ok, %WorkflowStep{step_type: :finish, config: nil} = step} =
               WorkflowSteps.insert(
                 workflow,
                 Map.merge(@valid_attrs, %{step_type: "finish", config: nil})
               )

      assert %{rows: [["finish"]]} =
               Repo.query!("SELECT step_type FROM workflow_steps WHERE id = $1", [
                 Ecto.UUID.dump!(step.id)
               ])
    end

    test "rejects a config on a finish step" do
      workflow = create_workflow()

      assert {:error, changeset} =
               WorkflowSteps.insert(workflow, %{
                 name: "Done",
                 step_type: "finish",
                 config: %{"prompt" => "Done"}
               })

      assert %{config: ["must be null for finish steps"]} = errors_on(changeset)
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

  describe "sync_transitions/2" do
    test "rejects outgoing transitions from a finish step" do
      workflow = create_workflow()

      {:ok, finish_step} =
        WorkflowSteps.insert(workflow, %{name: "Done", step_order: 1, step_type: "finish"})

      {:ok, target_step} = WorkflowSteps.insert(workflow, %{name: "Target", step_order: 2})

      assert {:error, :finish_step_cannot_have_outgoing_transition} =
               WorkflowSteps.sync_transitions(finish_step, [%{to_step_id: target_step.id}])
    end

    test "requires exactly one outgoing transition for a stop step" do
      workflow = create_workflow()

      {:ok, stop_step} =
        WorkflowSteps.insert(workflow, %{name: "Boundary", step_order: 1, step_type: "stop"})

      {:ok, first_target} = WorkflowSteps.insert(workflow, %{name: "First", step_order: 2})
      {:ok, second_target} = WorkflowSteps.insert(workflow, %{name: "Second", step_order: 3})

      assert {:error, :stop_step_requires_exactly_one_outgoing_transition} =
               WorkflowSteps.sync_transitions(stop_step, [])

      assert {:ok, [_transition]} =
               WorkflowSteps.sync_transitions(stop_step, [%{to_step_id: first_target.id}])

      assert {:error, :stop_step_requires_exactly_one_outgoing_transition} =
               WorkflowSteps.sync_transitions(stop_step, [
                 %{to_step_id: first_target.id},
                 %{to_step_id: second_target.id}
               ])
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
               WorkflowSteps.update(step, %{name: "Updated", goal: "New goal"})

      assert updated.name == "Updated"
      assert updated.goal == "New goal"
    end

    test "accepts an unchanged step_type" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)

      assert {:ok, updated} = WorkflowSteps.update(step, %{step_type: "llm_inference"})
      assert updated.step_type == :llm_inference
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

    test "rejects deleting a step assigned to multiple tasks without changing either record" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)
      {:ok, task_one} = create_task(workflow, step, "Task one")
      {:ok, task_two} = create_task(workflow, step, "Task two")

      assert {:error, :assigned_tasks} = WorkflowSteps.delete(step)

      assert {:ok, found_step} = WorkflowSteps.get(step.id)
      assert found_step.id == step.id

      assert %Task{title: "Task one", current_step_id: step_id} = Repo.get!(Task, task_one.id)
      assert step_id == step.id

      assert %Task{title: "Task two", current_step_id: step_id} = Repo.get!(Task, task_two.id)
      assert step_id == step.id
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
        "required" => ["result"],
        "additionalProperties" => false
      }

      attrs =
        Map.merge(@valid_attrs, %{
          step_type: "llm_inference",
          config: %{"output_schema" => schema}
        })

      assert {:ok, %WorkflowStep{config: %{output_schema: returned_schema}}} =
               WorkflowSteps.insert(workflow, attrs)

      assert returned_schema == schema
    end

    test "rejects non-map output_schema" do
      workflow = create_workflow()

      attrs = Map.merge(@valid_attrs, %{config: %{"output_schema" => "not a map"}})
      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{config: %{output_schema: ["is invalid"]}} = errors_on(changeset)
    end

    test "allows nil output_schema" do
      workflow = create_workflow()

      attrs = Map.merge(@valid_attrs, %{config: %{"output_schema" => nil}})

      assert {:ok, %WorkflowStep{config: %{output_schema: nil}}} =
               WorkflowSteps.insert(workflow, attrs)
    end

    test "accepts artifact persistence options with an output schema" do
      workflow = create_workflow()

      attrs =
        Map.merge(@valid_attrs, %{
          persistence_options: %{"artifact" => %{"logical_name" => "step_result"}},
          config: %{"output_schema" => @structured_output_schema}
        })

      assert {:ok, %WorkflowStep{persistence_options: persistence_options}} =
               WorkflowSteps.insert(workflow, attrs)

      assert persistence_options == %{"artifact" => %{"logical_name" => "step_result"}}
    end

    test "rejects artifact persistence on finish and stop steps" do
      workflow = create_workflow()

      for step_type <- ["finish", "stop"] do
        attrs =
          Map.merge(@valid_attrs, %{
            step_type: step_type,
            config: nil,
            persistence_options: %{"artifact" => %{"logical_name" => "step_result"}}
          })

        assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)

        assert %{persistence_options: messages} = errors_on(changeset)
        assert "artifact persistence is not supported for #{step_type} steps" in messages
      end
    end

    test "requires an output schema when artifact persistence is configured" do
      workflow = create_workflow()

      attrs =
        Map.put(@valid_attrs, :persistence_options, %{
          "artifact" => %{"logical_name" => "step_result"}
        })

      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)

      assert %{persistence_options: ["artifact persistence requires output_schema"]} =
               errors_on(changeset)
    end

    test "rejects unknown persistence options" do
      workflow = create_workflow()

      attrs =
        Map.merge(@valid_attrs, %{
          persistence_options: %{"unknown" => true},
          config: %{"output_schema" => @structured_output_schema}
        })

      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{persistence_options: [_error | _]} = errors_on(changeset)
    end

    test "requires a nonblank artifact logical name" do
      workflow = create_workflow()

      attrs =
        Map.merge(@valid_attrs, %{
          persistence_options: %{"artifact" => %{"logical_name" => "   "}},
          config: %{"output_schema" => @structured_output_schema}
        })

      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{persistence_options: [_error | _]} = errors_on(changeset)
    end

    test "prevents clearing output_schema while artifact persistence is configured" do
      workflow = create_workflow()

      {:ok, step} =
        WorkflowSteps.insert(workflow, %{
          name: "Persisted step",
          persistence_options: %{"artifact" => %{"logical_name" => "step_result"}},
          config: %{"output_schema" => @structured_output_schema}
        })

      assert {:error, changeset} =
               WorkflowSteps.update(step, %{config: %{"output_schema" => nil}})

      assert %{persistence_options: ["artifact persistence requires output_schema"]} =
               errors_on(changeset)
    end

    test "preserves output_schema on update for evaluate steps" do
      workflow = create_workflow()

      schema = %{
        "type" => "object",
        "properties" => %{
          "data" => %{"type" => "string"}
        },
        "required" => ["data"],
        "additionalProperties" => false
      }

      {:ok, step} =
        WorkflowSteps.insert(
          workflow,
          Map.merge(@valid_attrs, %{
            step_type: "llm_inference",
            config: %{"output_schema" => schema}
          })
        )

      updated_schema = %{
        "type" => "object",
        "properties" => %{
          "new_data" => %{"type" => "integer"}
        },
        "required" => ["new_data"],
        "additionalProperties" => false
      }

      {:ok, updated} =
        WorkflowSteps.update(step, %{
          config: %{"output_schema" => updated_schema}
        })

      assert updated.config.output_schema == updated_schema
    end

    test "rejects schemas with const values" do
      workflow = create_workflow()

      schema = %{
        "type" => "object",
        "properties" => %{
          "snapshot_type" => %{"const" => "wait_children_status"}
        },
        "required" => ["snapshot_type"],
        "additionalProperties" => false
      }

      attrs =
        Map.merge(@valid_attrs, %{
          step_type: "llm_inference",
          config: %{"output_schema" => schema, "agent_config" => %{"provider" => "codex"}}
        })

      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{config: %{output_schema: [message]}} = errors_on(changeset)
      assert String.contains?(message, "Codex strict-compatible")
      assert String.contains?(message, "const is not supported")
    end

    test "rejects schema nodes without explicit type strings" do
      workflow = create_workflow()

      schema = %{
        "type" => "object",
        "properties" => %{
          "route_hint" => %{
            "properties" => %{
              "transition_to" => %{"type" => "string"}
            },
            "required" => ["transition_to"],
            "additionalProperties" => false
          }
        },
        "required" => ["route_hint"],
        "additionalProperties" => false
      }

      attrs =
        Map.merge(@valid_attrs, %{
          step_type: "llm_inference",
          config: %{"output_schema" => schema, "agent_config" => %{"provider" => "openai"}}
        })

      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{config: %{output_schema: [message]}} = errors_on(changeset)
      assert String.contains?(message, "Codex strict-compatible")
      assert String.contains?(message, "schema.route_hint.type must be a string")
    end

    test "rejects object schemas without strict required and additionalProperties" do
      workflow = create_workflow()

      schema = %{
        "type" => "object",
        "properties" => %{
          "counts" => %{"type" => "object"}
        },
        "required" => ["counts"],
        "additionalProperties" => false
      }

      attrs =
        Map.merge(@valid_attrs, %{
          step_type: "llm_inference",
          config: %{"output_schema" => schema, "agent_config" => %{"provider" => "openai"}}
        })

      assert {:error, changeset} = WorkflowSteps.insert(workflow, attrs)
      assert %{config: %{output_schema: [message]}} = errors_on(changeset)
      assert String.contains?(message, "Codex strict-compatible")
      assert String.contains?(message, "additionalProperties must be false")
    end

    test "allows valid JSON Schema that is not Codex strict for Anthropic provider" do
      workflow = create_workflow()

      schema = %{
        "type" => "object",
        "properties" => %{
          "snapshot_type" => %{"const" => "wait_children_status"},
          "counts" => %{"type" => "object"}
        },
        "required" => ["snapshot_type"]
      }

      attrs =
        Map.merge(@valid_attrs, %{
          step_type: "llm_inference",
          config: %{"output_schema" => schema, "agent_config" => %{"provider" => "anthropic"}}
        })

      assert {:ok, %WorkflowStep{config: %{output_schema: returned_schema}}} =
               WorkflowSteps.insert(workflow, attrs)

      assert returned_schema == schema
    end

    test "rejects an existing loose schema when provider changes to OpenAI" do
      workflow = create_workflow()

      schema = %{
        "type" => "object",
        "properties" => %{"result" => %{"type" => "string"}}
      }

      {:ok, step} =
        WorkflowSteps.insert(
          workflow,
          Map.merge(@valid_attrs, %{
            step_type: "llm_inference",
            config: %{"output_schema" => schema, "agent_config" => %{"provider" => "anthropic"}}
          })
        )

      assert {:error, changeset} =
               WorkflowSteps.update(step, %{
                 config: %{"agent_config" => %{"provider" => "openai"}}
               })

      assert %{config: %{output_schema: [message]}} = errors_on(changeset)
      assert String.contains?(message, "Codex strict-compatible")
      assert String.contains?(message, "additionalProperties must be false")
    end
  end

  describe "verbose_daemon_logging field" do
    test "insert ignores verbose_daemon_logging in attrs (defaults to false)" do
      workflow = create_workflow()
      attrs = Map.merge(@valid_attrs, %{verbose_daemon_logging: true})
      {:ok, step} = WorkflowSteps.insert(workflow, attrs)

      assert step.verbose_daemon_logging == false
    end

    test "update ignores verbose_daemon_logging in attrs (remains unchanged)" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)
      assert step.verbose_daemon_logging == false

      {:ok, updated} = WorkflowSteps.update(step, %{verbose_daemon_logging: true})
      assert updated.verbose_daemon_logging == false
    end

    test "set_verbose_logging can set the flag to true" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)

      {:ok, updated} = WorkflowSteps.set_verbose_logging(step, true)
      assert updated.verbose_daemon_logging == true
    end

    test "set_verbose_logging can set the flag to false" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)
      {:ok, enabled} = WorkflowSteps.set_verbose_logging(step, true)

      {:ok, disabled} = WorkflowSteps.set_verbose_logging(enabled, false)
      assert disabled.verbose_daemon_logging == false
    end

    test "defaults to false on creation" do
      workflow = create_workflow()
      {:ok, step} = WorkflowSteps.insert(workflow, @valid_attrs)

      assert step.verbose_daemon_logging == false
    end
  end
end
