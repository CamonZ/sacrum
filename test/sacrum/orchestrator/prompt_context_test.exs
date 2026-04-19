defmodule Sacrum.Orchestrator.PromptContextTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.PromptContext
  alias Sacrum.Repo

  # ===== Setup helpers =====

  defp create_user do
    unique_suffix = :erlang.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "prompt_context_test_#{unique_suffix}@example.com",
        username: "prompt_context_test_#{unique_suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    unique_suffix = :erlang.unique_integer([:positive])

    {:ok, project} =
      Accounts.Projects.insert(user.id, %{name: "PC Test Project #{unique_suffix}"})

    project
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Test Workflow",
        auto_advance: false,
        workflow_steps: []
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

  defp create_task(user, project, workflow) do
    # Ensure workflow has at least one step
    workflow = Repo.preload(workflow, :workflow_steps)

    workflow =
      case workflow.workflow_steps do
        [] ->
          # Create a default step if none exists
          create_step(user, workflow, %{})
          Repo.preload(Repo.get!(Sacrum.Repo.Schemas.Workflow, workflow.id), :workflow_steps)

        _ ->
          workflow
      end

    # Set initial step if not already set
    workflow =
      if is_nil(workflow.initial_step_id) do
        first_step =
          workflow.workflow_steps
          |> Enum.sort_by(& &1.step_order)
          |> hd()

        {:ok, w} = Accounts.Workflows.update(workflow, %{initial_step_id: first_step.id})
        w
      else
        workflow
      end

    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Test Task",
        description: "A test task description",
        level: "ticket",
        tags: ["test"],
        sections: [],
        code_refs: []
      })

    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    Repo.preload(task, [:sections, :code_refs, :workflow])
  end

  # ===== Tests =====

  describe "build_context/3" do
    test "combines task, execution, and workflow contexts" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{"output_schema" => %{"type" => "object"}})
      step_with_workflow = Repo.preload(step, :workflow)
      task = create_task(user, project, workflow)
      task_with_workflow = Repo.preload(task, :workflow)

      execution_data = %{
        previous: %{output: "some output"},
        run_count: 2,
        completed_count: 1,
        failed_count: 1
      }

      context =
        PromptContext.build_context(task_with_workflow, execution_data, step_with_workflow)

      assert is_map(context)
      assert Map.has_key?(context, "task")
      assert Map.has_key?(context, "execution")
      assert Map.has_key?(context, "workflow")

      assert context["task"]["id"] == to_string(task.id)
      assert context["task"]["title"] == "Test Task"
      assert context["execution"]["run_count"] == 2
      assert context["workflow"]["name"] == "Test Workflow"
    end

    test "handles nil workflow_step gracefully" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      task = create_task(user, project, workflow)

      execution_data = %{}

      context = PromptContext.build_context(task, execution_data, nil)

      assert context["task"]["id"] == to_string(task.id)
      assert context["workflow"] == %{}
    end
  end

  describe "build_task_context/1" do
    test "includes all base task fields" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      task = create_task(user, project, workflow)

      context = PromptContext.build_task_context(task)

      assert context["id"] == to_string(task.id)
      assert context["title"] == "Test Task"
      assert context["description"] == "A test task description"
      assert context["level"] == "ticket"
      assert context["tags"] == ["test"]
    end

    test "includes code_refs as a list of maps" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      task = create_task(user, project, workflow)

      # Create and add a code ref
      {:ok, _ref} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/test.ex",
          line_start: 10,
          line_end: 20,
          name: "test_function",
          description: "A test function"
        })

      # Reload the task from the database to get the new code_refs
      task_with_ref =
        Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
        |> Repo.preload([:code_refs, :sections])

      context = PromptContext.build_task_context(task_with_ref)

      assert is_list(context["code_refs"])
      assert length(context["code_refs"]) == 1
      assert Enum.at(context["code_refs"], 0)["path"] == "lib/test.ex"
    end

    test "groups sections by type" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      task = create_task(user, project, workflow)

      # Add sections
      {:ok, _} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "constraint",
          content: "Must be fast"
        })

      {:ok, _} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "goal",
          content: "Complete the feature"
        })

      # Reload the task from the database to get the new sections
      task_with_sections =
        Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
        |> Repo.preload([:sections, :code_refs])

      context = PromptContext.build_task_context(task_with_sections)

      assert Map.has_key?(context, "constraints")
      assert Map.has_key?(context, "goals")
      assert context["constraints"] == ["Must be fast"]
      assert context["goals"] == ["Complete the feature"]
    end
  end

  describe "build_execution_context/1" do
    test "extracts previous output and run counts" do
      execution_data = %{
        previous: %{output: "test output"},
        run_count: 3,
        completed_count: 2,
        failed_count: 1
      }

      context = PromptContext.build_execution_context(execution_data)

      assert context["previous_output"] == "test output"
      assert context["run_count"] == 3
      assert context["completed_count"] == 2
      assert context["failed_count"] == 1
    end

    test "handles binary and map previous output variants" do
      binary_data = %{previous: %{output: "string output"}}
      map_data = %{previous: %{output: %{"key" => "value"}}}
      list_data = %{previous: %{output: [1, 2, 3]}}

      assert PromptContext.build_execution_context(binary_data)["previous_output"] ==
               "string output"

      assert PromptContext.build_execution_context(map_data)["previous_output"] == %{
               "key" => "value"
             }

      assert PromptContext.build_execution_context(list_data)["previous_output"] == [1, 2, 3]
    end

    test "includes handoff data when present" do
      execution_data = %{handoff: %{"key" => "value"}}

      context = PromptContext.build_execution_context(execution_data)

      assert context["handoff"] == %{"key" => "value"}
    end

    test "returns empty map for non-map input" do
      context = PromptContext.build_execution_context("not a map")
      assert context == %{}
    end

    test "handles missing keys gracefully" do
      execution_data = %{}

      context = PromptContext.build_execution_context(execution_data)

      assert context["run_count"] == 0
      assert context["completed_count"] == 0
      assert context["failed_count"] == 0
      # previous_output defaults to empty string when not provided
      assert context["previous_output"] == ""
    end
  end

  describe "build_workflow_context/2" do
    test "includes workflow name and step information" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{"name" => "current_step", "goal" => "Do something"})
      step_with_workflow = Repo.preload(step, :workflow)

      task = create_task(user, project, workflow)
      task_with_workflow = Repo.preload(task, :workflow)

      context = PromptContext.build_workflow_context(step_with_workflow, task_with_workflow)

      assert context["name"] == "Test Workflow"
      assert context["current_step"] == "current_step"
      assert context["current_step_goal"] == "Do something"
    end

    test "includes output_schema when present on step" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      schema = %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
      step = create_step(user, workflow, %{"output_schema" => schema})
      step_with_workflow = Repo.preload(step, :workflow)

      task = create_task(user, project, workflow)
      task_with_workflow = Repo.preload(task, :workflow)

      context = PromptContext.build_workflow_context(step_with_workflow, task_with_workflow)

      assert context["output_schema"] == schema
    end

    test "returns empty map when workflow_step is nil" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      task = create_task(user, project, workflow)

      context = PromptContext.build_workflow_context(nil, task)

      assert context == %{}
    end

    test "counts workflow steps correctly" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step1 = create_step(user, workflow, %{"name" => "step1", "step_order" => 1})
      step2 = create_step(user, workflow, %{"name" => "step2", "step_order" => 2})

      task = create_task(user, project, workflow)
      task_with_workflow = Repo.preload(task, :workflow)
      step1_with_workflow = Repo.preload(step1, workflow: :workflow_steps)

      context = PromptContext.build_workflow_context(step1_with_workflow, task_with_workflow)

      # The step's workflow association is loaded, so it uses step.workflow
      assert context["step_count"] == 2
    end
  end
end
