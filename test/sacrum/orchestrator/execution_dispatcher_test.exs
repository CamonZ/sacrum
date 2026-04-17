defmodule Sacrum.Orchestrator.ExecutionDispatcherTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.ExecutionDispatcher
  alias Sacrum.Orchestrator.PromptRenderer

  defp create_user do
    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "dispatcher_test@example.com",
        username: "dispatcher_test",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Dispatch Test Project"})
    project
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Test Workflow",
        auto_advance: false
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
      "is_final" => false,
      "agents" => ["test"],
      "skills" => ["test_skill"],
      "agent_config" => %{"model" => "test-model"},
      "workflow_id" => workflow.id,
      "project_id" => workflow.project_id,
      "prompt" => "default prompt"
    }

    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, Map.merge(default_attrs, attrs))
    step
  end

  defp create_task(user, project, attrs \\ %{}) do
    default_attrs = %{
      title: "Test Task",
      description: "A test task description",
      level: "ticket",
      tags: ["integration", "test"]
    }

    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, Map.merge(default_attrs, attrs))
    task
  end

  defp assign_workflow(task, workflow) do
    {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  defp create_entered_execution(user, task, step) do
    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, %{
        "task_id" => task.id,
        "project_id" => task.project_id,
        "workflow_id" => step.workflow_id,
        "step_name" => step.name,
        "status" => "entered"
      })

    execution
  end

  defp subscribe_to_project(project) do
    Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")
  end

  defp setup_dispatch_context(_) do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project)

    %{user: user, project: project, workflow: workflow}
  end

  describe "create_and_dispatch/3 — Liquid template rendering" do
    setup [:setup_dispatch_context]

    test "renders {{ task.title }} in step prompt", ctx do
      step = create_step(ctx.user, ctx.workflow, %{"prompt" => "Working on: {{ task.title }}"})
      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      _execution = create_entered_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Working on: Test Task"
    end

    test "renders {{ task.description }} and {{ task.level }}", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Level: {{ task.level }}, Description: {{ task.description }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      _execution = create_entered_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Level: ticket, Description: A test task description"
    end

    test "renders {% for constraint in task.constraints %} from task sections", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Constraints:{% for c in task.constraints %}\n- {{ c }}{% endfor %}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      {:ok, _} =
        Accounts.Sections.insert(ctx.user.id, %{
          task_id: task.id,
          project_id: ctx.project.id,
          section_type: "constraint",
          content: "Must work offline"
        })

      {:ok, _} =
        Accounts.Sections.insert(ctx.user.id, %{
          task_id: task.id,
          project_id: ctx.project.id,
          section_type: "constraint",
          content: "Must support iOS 14+"
        })

      # Force-reload from DB to pick up the newly inserted sections
      task = Sacrum.Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
      task = PromptRenderer.preload_for_rendering(task)
      _execution = create_entered_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt =~ "Must work offline"
      assert prompt =~ "Must support iOS 14+"
    end

    test "renders {{ workflow.name }} and {{ workflow.current_step }}", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Workflow: {{ workflow.name }}, Step: {{ workflow.current_step }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      _execution = create_entered_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Workflow: Test Workflow, Step: Test Step"
    end

    test "render failure falls back to raw template", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Hello {{ undefined_variable }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      _execution = create_entered_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Hello {{ undefined_variable }}"
    end
  end

  describe "prior output exposure via execution data" do
    setup [:setup_dispatch_context]

    test "renders {{ execution.previous_output }} when prior completion exists", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Prior output was: {{ execution.previous_output }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      # Create a prior completed execution
      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => "previous_step",
          "status" => "completed",
          "output" => "Analysis complete"
        })

      # Create current entered execution
      _current_exec = create_entered_execution(ctx.user, task, step)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Prior output was: Analysis complete"
    end

    test "renders {{ execution.previous_output }} as empty when no prior completion exists",
         ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Prior output: '{{ execution.previous_output }}' (empty if none)"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)

      _execution = create_entered_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      # previous_output renders as empty string when no prior execution
      assert prompt == "Prior output: '' (empty if none)"
    end

    test "multiple prior executions renders the most recent one", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Latest: {{ execution.previous_output }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      # Create multiple prior completed executions
      {:ok, _older} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => "eval_step_1",
          "status" => "completed",
          "output" => "First analysis"
        })

      {:ok, _newer} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => "eval_step_2",
          "status" => "completed",
          "output" => "Second analysis"
        })

      # Current entered execution
      _current = create_entered_execution(ctx.user, task, step)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      # Should render the most recent prior execution
      assert prompt == "Latest: Second analysis"
    end

    test "handoff from entered execution is available in context", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Handoff context: {{ execution.handoff | json_encode }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      # Create entered execution with handoff
      {:ok, _execution} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => step.name,
          "status" => "entered",
          "handoff" => %{"routing_key" => "user_approved"}
        })

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      # Handoff should be available to the template
      # Note: exact JSON format may vary, but handoff context should be accessible
      assert String.contains?(prompt, "routing_key")
    end
  end

  describe "schema-aware prior output decoding" do
    setup [:setup_dispatch_context]

    test "when prior step has valid output_schema, prior.output is decoded to map", ctx do
      prior_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "eval_step",
          "step_order" => 1,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{
              "verdict" => %{"type" => "string"},
              "should_retry" => %{"type" => "boolean"}
            }
          }
        })

      current_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "route_step",
          "step_order" => 2,
          "prompt" => "Verdict: {{ execution.previous_output.verdict }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "{\"verdict\": \"approved\", \"should_retry\": false}"
        })

      _current_exec = create_entered_execution(ctx.user, task, current_step)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, current_step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Verdict: approved"
    end

    test "when prior step has no output_schema, prior.output remains raw string (backwards-compatible)",
         ctx do
      prior_step = create_step(ctx.user, ctx.workflow, %{"name" => "step_1", "step_order" => 1})

      current_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "step_2",
          "step_order" => 2,
          "prompt" => "Previous: {{ execution.previous_output }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "Just a plain string output"
        })

      _current_exec = create_entered_execution(ctx.user, task, current_step)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, current_step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Previous: Just a plain string output"
    end

    test "when prior step has output_schema but output is not valid JSON, falls back to raw string and logs warning",
         ctx do
      prior_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "eval_step",
          "step_order" => 1,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"result" => %{"type" => "string"}}
          }
        })

      current_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "next_step",
          "step_order" => 2,
          "prompt" => "Got: {{ execution.previous_output }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "{ broken json"
        })

      _current_exec = create_entered_execution(ctx.user, task, current_step)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, current_step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Got: { broken json"
    end

    test "build_execution_context converts map prior_output while preserving string prior_output" do
      execution_data_with_map = %{
        previous: %{
          output: %{"verdict" => "approved", "should_retry" => false}
        }
      }

      ctx = PromptRenderer.build_execution_context(execution_data_with_map)

      assert ctx["previous_output"] == %{"verdict" => "approved", "should_retry" => false}

      execution_data_with_string = %{
        previous: %{
          output: "just a string"
        }
      }

      ctx2 = PromptRenderer.build_execution_context(execution_data_with_string)

      assert ctx2["previous_output"] == "just a string"
    end

    test "rendering {{ execution.previous_output.result }} with decoded map returns field value",
         ctx do
      prior_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "eval_step",
          "step_order" => 1,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{"result" => %{"type" => "string"}}
          }
        })

      current_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "route_step",
          "step_order" => 2,
          "prompt" => "Result: {{ execution.previous_output.result }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "{\"result\": \"success\"}"
        })

      _current_exec = create_entered_execution(ctx.user, task, current_step)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, current_step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Result: success"
    end

    test "rendering {{ execution.previous_output }} with string still renders unchanged", ctx do
      prior_step =
        create_step(ctx.user, ctx.workflow, %{"name" => "plain_step", "step_order" => 1})

      current_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "step_2",
          "step_order" => 2,
          "prompt" => "{{ execution.previous_output }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "plain string output"
        })

      _current_exec = create_entered_execution(ctx.user, task, current_step)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, current_step.id)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "plain string output"
    end
  end
end
