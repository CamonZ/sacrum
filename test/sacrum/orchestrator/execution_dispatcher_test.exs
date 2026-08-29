defmodule Sacrum.Orchestrator.ExecutionDispatcherTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, PromptContext, PromptRenderer}

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
        name: "Test Workflow"
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
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

  defp create_previous_execution(user, task, step, task_run \\ nil) do
    import Ecto.Query

    query =
      from(e in Sacrum.Repo.Schemas.StepExecution,
        where: e.task_id == ^task.id and e.step_id == ^step.id and e.status == "invalidated",
        limit: 1
      )

    query =
      if task_run do
        where(query, [e], e.task_run_id == ^task_run.id)
      else
        query
      end

    case Sacrum.Repo.one(query) do
      nil ->
        attrs = %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => step.workflow_id,
          "step_id" => step.id,
          "step_name" => step.name,
          "status" => "invalidated"
        }

        attrs = if task_run, do: Map.put(attrs, "task_run_id", task_run.id), else: attrs

        {:ok, execution} = Accounts.StepExecutions.insert(user.id, attrs)

        execution

      execution ->
        execution
    end
  end

  defp subscribe_to_project(project) do
    Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")
  end

  defp create_task_run(ctx, task) do
    {:ok, task_run} =
      Accounts.TaskRuns.insert(ctx.user.id, task.project_id, task.id, %{status: :queued})

    task_run
  end

  defp create_and_dispatch(ctx, task, step, handoff \\ nil) do
    task_run = create_task_run(ctx, task)
    ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id, task_run, handoff)
  end

  defp create_and_dispatch_with_run(ctx, task, step, task_run, handoff \\ nil) do
    ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id, task_run, handoff)
  end

  defp setup_dispatch_context(_) do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project)

    %{user: user, project: project, workflow: workflow}
  end

  describe "create_and_dispatch/3 — Liquid template rendering" do
    setup [:setup_dispatch_context]

    test "persists the source workflow step_type on dispatched executions", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "Human approval",
          "step_type" => "human_input",
          "prompt" => "wait for human"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)

      {:ok, exec} = create_and_dispatch(ctx, task, step)

      assert exec.step_name == "Human approval"
      assert exec.step_type == :human_input
    end

    test "rejects direct dispatch of a stop step without changing the TaskRun", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "Run boundary",
          "step_type" => "stop",
          "prompt" => nil
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      assert {:error, :stop_step_not_dispatchable} =
               ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id, task_run)

      assert Sacrum.Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id).status == :queued

      assert Sacrum.Repo.get_by(Sacrum.Repo.Schemas.StepExecution,
               task_run_id: task_run.id
             ) == nil
    end

    test "rejects direct dispatch of a configured route without creating daemon work", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "Configured route",
          "step_type" => "route"
        })

      {:ok, step} =
        Sacrum.Repo.update(
          Ecto.Changeset.change(step, %{
            route_config: %{"version" => 999}
          })
        )

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      assert {:error, :configured_route_not_dispatchable} =
               ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id, task_run)

      assert Sacrum.Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id).status == :queued

      assert Sacrum.Repo.get_by(Sacrum.Repo.Schemas.StepExecution,
               task_run_id: task_run.id
             ) == nil
    end

    test "rejects an unconfigured promptless route before creating daemon work", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "Unconfigured route",
          "step_type" => "route",
          "prompt" => nil
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      assert {:error, :route_not_configured} =
               ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id, task_run)

      assert Sacrum.Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id).status == :queued

      assert Sacrum.Repo.get_by(Sacrum.Repo.Schemas.StepExecution,
               task_run_id: task_run.id
             ) == nil
    end

    test "renders {{ task.title }} in step prompt", ctx do
      step = create_step(ctx.user, ctx.workflow, %{"prompt" => "Working on: {{ task.title }}"})
      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      _execution = create_previous_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch(ctx, task, step)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Working on: Test Task"
    end

    test "renders project and task artifact IDs and persists/broadcasts the same prompt", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" =>
            ~s|Project: {{ artifacts["project"]["result"].id }} Task: {{ artifacts["task"]["result"].id }}|
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)

      {:ok, %{artifact: project_artifact}} =
        Accounts.Artifacts.create_and_link(
          ctx.user.id,
          ctx.project.id,
          %{filename: "project-result.json", body: "private project body"},
          %{subject_type: "project", subject_id: ctx.project.id, logical_name: "result"}
        )

      {:ok, %{artifact: task_artifact}} =
        Accounts.Artifacts.create_and_link(
          ctx.user.id,
          ctx.project.id,
          %{filename: "result.json", body: "private result body"},
          %{subject_type: "task", subject_id: task.id, logical_name: "result"}
        )

      task = PromptRenderer.preload_for_rendering(task)

      assert [%{id: artifact_id, logical_name: "result"}] =
               Accounts.Artifacts.list_identities_for_subject(
                 task.user_id,
                 task.project_id,
                 "task",
                 task.id
               )

      assert artifact_id == task_artifact.id
      subscribe_to_project(ctx.project)

      {:ok, dispatched} = create_and_dispatch(ctx, task, step)

      expected = "Project: #{project_artifact.id} Task: #{task_artifact.id}"
      assert dispatched.prompt == expected
      assert Sacrum.Repo.get!(Sacrum.Repo.Schemas.StepExecution, dispatched.id).prompt == expected

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: ^expected}
      }
    end

    test "renders the current TaskRun artifact ID without exposing its body", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => ~s|Run artifact: {{ artifacts["task_run"]["result"].id }}|
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      {:ok, %{artifact: artifact}} =
        Accounts.Artifacts.create_and_link(
          ctx.user.id,
          ctx.project.id,
          %{filename: "task-run-result.json", body: "private task-run body"},
          %{subject_type: "task_run", subject_id: task_run.id, logical_name: "result"}
        )

      task = PromptRenderer.preload_for_rendering(task)
      subscribe_to_project(ctx.project)

      {:ok, dispatched} =
        ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id, task_run)

      expected = "Run artifact: #{artifact.id}"
      assert dispatched.prompt == expected
      refute inspect(dispatched.prompt) =~ "private task-run body"

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: ^expected}
      }
    end

    test "renders {{ task.description }} and {{ task.level }}", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Level: {{ task.level }}, Description: {{ task.description }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      _execution = create_previous_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch(ctx, task, step)

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
      _execution = create_previous_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch(ctx, task, step)

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
      _execution = create_previous_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch(ctx, task, step)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Workflow: Test Workflow, Step: Test Step"
    end

    test "undefined variables render as empty", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Hello {{ undefined_variable }}!"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      _execution = create_previous_execution(ctx.user, task, step)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch(ctx, task, step)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Hello !"
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
      task_run = create_task_run(ctx, task)

      # Create a prior completed execution
      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => "previous_step",
          "status" => "completed",
          "output" => "Analysis complete"
        })

      _current_exec = create_previous_execution(ctx.user, task, step, task_run)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, step, task_run)

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
      task_run = create_task_run(ctx, task)
      task = PromptRenderer.preload_for_rendering(task)

      _execution = create_previous_execution(ctx.user, task, step, task_run)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, step, task_run)

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
      task_run = create_task_run(ctx, task)

      # Create multiple prior completed executions
      {:ok, _older} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => "eval_step_1",
          "status" => "completed",
          "output" => "First analysis"
        })

      {:ok, _newer} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => "eval_step_2",
          "status" => "completed",
          "output" => "Second analysis"
        })

      _current = create_previous_execution(ctx.user, task, step, task_run)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, step, task_run)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      # Should render the most recent prior execution
      assert prompt == "Latest: Second analysis"
    end

    test "handoff passed to create_and_dispatch is available in context", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Handoff context: {{ execution.handoff | json_encode }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} =
        create_and_dispatch(ctx, task, step, %{
          "routing_key" => "user_approved"
        })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

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
            },
            "required" => ["verdict", "should_retry"],
            "additionalProperties" => false
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
      task_run = create_task_run(ctx, task)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "{\"verdict\": \"approved\", \"should_retry\": false}"
        })

      _current_exec = create_previous_execution(ctx.user, task, current_step, task_run)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, current_step, task_run)

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
      task_run = create_task_run(ctx, task)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "Just a plain string output"
        })

      _current_exec = create_previous_execution(ctx.user, task, current_step, task_run)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, current_step, task_run)

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
            "properties" => %{"result" => %{"type" => "string"}},
            "required" => ["result"],
            "additionalProperties" => false
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
      task_run = create_task_run(ctx, task)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "{ broken json"
        })

      _current_exec = create_previous_execution(ctx.user, task, current_step, task_run)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, current_step, task_run)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Got: { broken json"
    end

    test "when prior output is wrapped in markdown code fences, strips them and decodes JSON",
         ctx do
      prior_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "eval_step",
          "step_order" => 1,
          "output_schema" => %{
            "type" => "object",
            "properties" => %{
              "verdict" => %{"type" => "string"},
              "confidence" => %{"type" => "number"}
            },
            "required" => ["verdict", "confidence"],
            "additionalProperties" => false
          }
        })

      current_step =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "route_step",
          "step_order" => 2,
          "prompt" =>
            "Verdict: {{ execution.previous_output.verdict }}, Confidence: {{ execution.previous_output.confidence }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task_run = create_task_run(ctx, task)

      # Simulate CLI wrapping output in markdown code fences
      fenced_output = "```json\n{\"verdict\": \"approved\", \"confidence\": 0.95}\n```"

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => fenced_output
        })

      _current_exec = create_previous_execution(ctx.user, task, current_step, task_run)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, current_step, task_run)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Verdict: approved, Confidence: 0.95"
    end

    test "build_execution_context converts map prior_output while preserving string prior_output" do
      execution_data_with_map = %{
        previous: %{
          output: %{"verdict" => "approved", "should_retry" => false}
        }
      }

      ctx = PromptContext.build_execution_context(execution_data_with_map)

      assert ctx["previous_output"] == %{"verdict" => "approved", "should_retry" => false}

      execution_data_with_string = %{
        previous: %{
          output: "just a string"
        }
      }

      ctx2 = PromptContext.build_execution_context(execution_data_with_string)

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
            "properties" => %{"result" => %{"type" => "string"}},
            "required" => ["result"],
            "additionalProperties" => false
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
      task_run = create_task_run(ctx, task)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "{\"result\": \"success\"}"
        })

      _current_exec = create_previous_execution(ctx.user, task, current_step, task_run)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, current_step, task_run)

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
      task_run = create_task_run(ctx, task)

      {:ok, _prior_exec} =
        Accounts.StepExecutions.insert(ctx.user.id, %{
          "task_id" => task.id,
          "task_run_id" => task_run.id,
          "project_id" => task.project_id,
          "workflow_id" => ctx.workflow.id,
          "step_name" => prior_step.name,
          "status" => "completed",
          "output" => "plain string output"
        })

      _current_exec = create_previous_execution(ctx.user, task, current_step, task_run)

      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} = create_and_dispatch_with_run(ctx, task, current_step, task_run)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "plain string output"
    end
  end

  describe "run count exposure via execution data" do
    setup [:setup_dispatch_context]

    test "renders {{ execution.run_count }} with count of prior completed and failed executions",
         ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "This is run number {{ execution.run_count }}"
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      insert_execution(ctx, task, step.name, "completed", task_run)
      insert_execution(ctx, task, step.name, "completed", task_run)
      insert_execution(ctx, task, step.name, "failed", task_run)
      create_previous_execution(ctx.user, task, step, task_run)

      assert dispatch_prompt(ctx, task, step, task_run) == "This is run number 3"
    end

    test "run_count is 0 when no prior executions exist for the step", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Run count: {{ execution.run_count }}"
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      create_previous_execution(ctx.user, task, step, task_run)

      assert dispatch_prompt(ctx, task, step, task_run) == "Run count: 0"
    end

    test "run_count excludes 'invalidated' status executions", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Run count is {{ execution.run_count }}"
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      insert_execution(ctx, task, step.name, "completed", task_run)
      insert_execution(ctx, task, step.name, "invalidated", task_run)
      create_previous_execution(ctx.user, task, step, task_run)

      assert dispatch_prompt(ctx, task, step, task_run) == "Run count is 1"
    end

    test "splits run count into completed_count and failed_count", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" =>
            "total={{ execution.run_count }} ok={{ execution.completed_count }} ko={{ execution.failed_count }}"
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      insert_execution(ctx, task, step.name, "completed", task_run)
      insert_execution(ctx, task, step.name, "completed", task_run)
      insert_execution(ctx, task, step.name, "failed", task_run)
      create_previous_execution(ctx.user, task, step, task_run)

      assert dispatch_prompt(ctx, task, step, task_run) == "total=3 ok=2 ko=1"
    end

    test "run_count is specific to the current step", ctx do
      step_a = create_step(ctx.user, ctx.workflow, %{"name" => "step_a", "step_order" => 1})

      step_b =
        create_step(ctx.user, ctx.workflow, %{
          "name" => "step_b",
          "step_order" => 2,
          "prompt" => "Step B run count: {{ execution.run_count }}"
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task_run = create_task_run(ctx, task)

      insert_execution(ctx, task, step_a.name, "completed", task_run)
      insert_execution(ctx, task, step_a.name, "completed", task_run)
      insert_execution(ctx, task, step_b.name, "completed", task_run)
      create_previous_execution(ctx.user, task, step_b, task_run)

      assert dispatch_prompt(ctx, task, step_b, task_run) == "Step B run count: 1"
    end
  end

  defp insert_execution(ctx, task, step_name, status, task_run) do
    attrs = %{
      "task_id" => task.id,
      "project_id" => task.project_id,
      "workflow_id" => ctx.workflow.id,
      "step_name" => step_name,
      "status" => status
    }

    attrs = if task_run, do: Map.put(attrs, "task_run_id", task_run.id), else: attrs

    {:ok, exec} = Accounts.StepExecutions.insert(ctx.user.id, attrs)

    exec
  end

  defp dispatch_prompt(ctx, task, step, task_run) do
    task = PromptRenderer.preload_for_rendering(task)
    subscribe_to_project(ctx.project)

    {:ok, _exec} = create_and_dispatch_with_run(ctx, task, step, task_run)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "run_step",
      payload: %{prompt: prompt}
    }

    prompt
  end

  describe "prompt persistence" do
    setup [:setup_dispatch_context]

    test "attaches execution to TaskRun and moves the run to executing", ctx do
      step = create_step(ctx.user, ctx.workflow, %{})
      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      task_run = create_task_run(ctx, task)

      subscribe_to_project(ctx.project)

      {:ok, dispatched} =
        ExecutionDispatcher.create_and_dispatch(ctx.user.id, task, step.id, task_run)

      reloaded_run = Sacrum.Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id)

      assert dispatched.task_run_id == task_run.id
      assert reloaded_run.status == :executing
      assert reloaded_run.latest_step_execution_id == dispatched.id
      assert reloaded_run.ended_at == nil
    end

    test "marks TaskRun failed when dispatch fails after run creation", ctx do
      _step = create_step(ctx.user, ctx.workflow, %{})
      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)
      task_run = create_task_run(ctx, task)

      assert {:error, :not_found} =
               ExecutionDispatcher.create_and_dispatch(
                 ctx.user.id,
                 task,
                 Ecto.UUID.generate(),
                 task_run
               )

      failed_run = Sacrum.Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id)
      assert failed_run.status == :failed
      assert %DateTime{} = failed_run.ended_at
      assert failed_run.outcome_kind == "dispatch_failed"
      assert failed_run.outcome_context["reason"] == "not_found"
    end

    test "persists rendered prompt on the execution row and broadcasts the same text", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "prompt" => "Task: {{ task.title }} | Level: {{ task.level }}"
        })

      task = create_task(ctx.user, ctx.project) |> assign_workflow(ctx.workflow)

      task = PromptRenderer.preload_for_rendering(task)
      subscribe_to_project(ctx.project)

      {:ok, dispatched} = create_and_dispatch(ctx, task, step)

      expected = "Task: Test Task | Level: ticket"
      assert dispatched.prompt == expected
      assert Sacrum.Repo.get!(Sacrum.Repo.Schemas.StepExecution, dispatched.id).prompt == expected

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: ^expected}
      }
    end
  end
end
