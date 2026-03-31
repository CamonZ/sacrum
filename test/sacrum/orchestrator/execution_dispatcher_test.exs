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
          "prompt" =>
            "Constraints:{% for c in task.constraints %}\n- {{ c }}{% endfor %}"
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

  describe "create_and_dispatch_eval/4 — Liquid template rendering" do
    setup [:setup_dispatch_context]

    test "renders {{ execution.previous_output }} in eval prompt", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "eval_prompt" => "Previous output was: {{ execution.previous_output }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} =
        ExecutionDispatcher.create_and_dispatch_eval(
          ctx.user.id,
          task,
          step.id,
          "the agent completed step 1"
        )

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Previous output was: the agent completed step 1"
    end

    test "renders task context alongside output in eval prompt", ctx do
      step =
        create_step(ctx.user, ctx.workflow, %{
          "eval_prompt" =>
            "Task: {{ task.title }}\nOutput: {{ execution.previous_output }}"
        })

      task = create_task(ctx.user, ctx.project)
      task = assign_workflow(task, ctx.workflow)
      task = PromptRenderer.preload_for_rendering(task)

      subscribe_to_project(ctx.project)

      {:ok, _exec} =
        ExecutionDispatcher.create_and_dispatch_eval(
          ctx.user.id,
          task,
          step.id,
          "done"
        )

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{prompt: prompt}
      }

      assert prompt == "Task: Test Task\nOutput: done"
    end
  end
end
