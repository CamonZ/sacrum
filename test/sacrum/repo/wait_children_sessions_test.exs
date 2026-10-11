defmodule Sacrum.Repo.WaitChildrenSessionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.RouteValidation
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Routing.RouteValidator

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "wait_children_sessions_#{suffix}@example.com",
        username: "wait_children_sessions_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Wait Children Sessions"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Parent"})
    {:ok, other} = Accounts.Workflows.insert(user.id, project.id, %{name: "Other"})
    context = %{user: user, project: project, workflow: workflow}

    %{
      user: user,
      workflow: workflow,
      plan: create_step(context, "plan", 1),
      human: create_step(context, "human", 2, step_type: "human_input"),
      foreign: create_step(%{context | workflow: other}, "foreign", 1)
    }
  end

  test "saves a fork naming an llm_inference step of the parent's workflow", context do
    session = %{"mode" => "fork", "step_id" => context.plan.id}

    assert {:ok, step} = insert_wait(context, session)
    assert step.config.session == session
    assert Repo.get!(WorkflowStep, step.id).config.session == session
  end

  test "a wait_children step without a session stores none", context do
    assert {:ok, step} = insert_wait(context, nil)
    assert step.config.session == nil
  end

  test "rejects resume, new and a fork without step_id", context do
    for {session, message} <- [
          {%{"mode" => "resume", "step_id" => context.plan.id}, "$.session.mode: must be fork"},
          {%{"mode" => "new"}, "$.session.mode: must be fork"},
          {%{"mode" => "fork"}, "$.session.step_id: is required"},
          {%{"mode" => "fork", "step_id" => context.plan.id, "task_run_id" => context.plan.id},
           "$.session.task_run_id: is not allowed"}
        ] do
      assert {:error, changeset} = insert_wait(context, session)
      assert inspect(errors_on(changeset)) =~ message
    end
  end

  test "rejects a step outside llm_inference or the parent's workflow", context do
    for step <- [context.human, context.foreign] do
      assert {:error, changeset} =
               insert_wait(context, %{"mode" => "fork", "step_id" => step.id})

      assert errors_on(changeset).config == [
               "$.session.step_id: must be an llm_inference step in this workflow"
             ]
    end
  end

  test "rejects deleting the step the directive forks", context do
    {:ok, _wait} = insert_wait(context, %{"mode" => "fork", "step_id" => context.plan.id})

    assert {:error, changeset} = Accounts.WorkflowSteps.delete(context.plan)

    assert errors_on(changeset).config == [
             "$.session.step_id: must be an llm_inference step in this workflow"
           ]

    assert Repo.get(WorkflowStep, context.plan.id)
  end

  test "runtime loading proves stored directives", context do
    {:ok, wait} = insert_wait(context, %{"mode" => "fork", "step_id" => context.plan.id})

    wait
    |> Ecto.Changeset.change(
      config: %{wait.config | session: %{"mode" => "fork", "step_id" => context.human.id}}
    )
    |> Repo.update!()

    {:ok, snapshot} = RouteValidation.load_snapshot(context.workflow.id)

    assert {:error,
            %{code: :wait_children_session_invalid, path: "$.session.step_id", step_id: step_id}} =
             RouteValidator.validate_snapshot(snapshot, [context.workflow.id])

    assert step_id == wait.id
  end

  defp insert_wait(context, session) do
    config = if session, do: %{"session" => session}, else: %{}

    attrs =
      workflow_step_attrs(%{
        "name" => "wait",
        "step_order" => 10,
        "step_type" => "wait_children",
        "workflow_id" => context.workflow.id,
        "project_id" => context.workflow.project_id,
        "config" => config
      })

    Accounts.WorkflowSteps.insert(context.user.id, attrs)
  end

  defp create_step(%{user: user, workflow: workflow}, name, order, opts \\ []) do
    attrs =
      %{
        "name" => name,
        "step_order" => order,
        "workflow_id" => workflow.id,
        "project_id" => workflow.project_id
      }
      |> Map.merge(Map.new(opts, fn {key, value} -> {to_string(key), value} end))

    attrs =
      if Map.get(attrs, "step_type", "llm_inference") == "llm_inference",
        do: Map.put_new(attrs, "config", %{"prompt" => "Prompt for #{name}"}),
        else: attrs

    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, workflow_step_attrs(attrs))
    step
  end
end
