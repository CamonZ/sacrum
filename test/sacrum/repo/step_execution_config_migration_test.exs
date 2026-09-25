defmodule Sacrum.Repo.StepExecutionConfigMigrationTest do
  @moduledoc """
  Rolls the step_executions prompt-to-config migration back inside the
  sandbox transaction, seeds executions through the legacy `prompt` column,
  and migrates forward again. The DDL is transactional, so the sandbox
  rollback restores the schema for other tests.
  """

  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Repo.Users

  @version 20_260_926_120_000

  setup do
    {:ok, user} =
      Users.insert(%{
        email: "exec-migrate@example.com",
        username: "exec",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Migration"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Legacy"})

    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{title: "Legacy", level: "task"})

    step = fn attrs ->
      {:ok, step} =
        Accounts.WorkflowSteps.insert(
          user.id,
          Map.merge(%{workflow_id: workflow.id, project_id: project.id}, attrs)
        )

      step
    end

    %{
      task: task,
      llm:
        step.(%{
          name: "Implement",
          step_type: "llm_inference",
          config: %{"prompt" => "Do {{ task.title }}", "agents" => ["dev"]}
        }),
      wait: step.(%{name: "Wait", step_type: "wait_children"}),
      human: step.(%{name: "Approve", step_type: "human_input"})
    }
  end

  test "backfills config from the rendered prompt and the step config, and rolls back", ctx do
    migrate(:down, @version)

    llm = insert_legacy(ctx.task, ctx.llm, "Do Legacy")
    wait = insert_legacy(ctx.task, ctx.wait, nil)
    human = insert_legacy(ctx.task, ctx.human, "")

    orphan =
      insert_legacy(ctx.task, %{id: nil, name: "Deleted", step_type: :llm_inference}, "Old")

    migrate(:up)

    assert %Config.LlmInference{prompt: "Do Legacy", agents: ["dev"]} = config(llm)
    assert config(wait) == ctx.wait.config
    assert config(human) == nil
    assert %Config.LlmInference{prompt: "Old", agents: [], agent_config: %{}} = config(orphan)

    migrate(:down, @version)

    assert %{rows: rows} =
             Repo.query!(
               "SELECT prompt FROM step_executions WHERE id = ANY($1) ORDER BY step_name",
               [Enum.map([llm, wait, human, orphan], &Ecto.UUID.dump!/1)]
             )

    # human_input rendered an empty prompt; with no config it rolls back as null.
    assert rows == [[nil], ["Old"], ["Do Legacy"], [nil]]

    migrate(:up)
  end

  defp config(id), do: Repo.get!(StepExecution, id).config

  defp insert_legacy(task, step, prompt) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO step_executions
        (id, task_id, user_id, project_id, workflow_id, step_id, step_name, step_type, status,
         prompt, context, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'completed', $9, '{}', $10, $10)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(task.id),
        Ecto.UUID.dump!(task.user_id),
        Ecto.UUID.dump!(task.project_id),
        Map.get(step, :workflow_id) && Ecto.UUID.dump!(step.workflow_id),
        step.id && Ecto.UUID.dump!(step.id),
        step.name,
        Atom.to_string(step.step_type),
        prompt,
        now
      ]
    )

    id
  end

  # The migrator holds its lock in the caller while running each migration in
  # a task; the sandbox has one shared connection, so the lock must be off.
  defp migrate(:down, version), do: run_migrations(:down, to: version)
  defp migrate(:up), do: run_migrations(:up, all: true)

  defp run_migrations(direction, opts) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(
        Repo,
        Application.app_dir(:sacrum, "priv/repo/migrations"),
        direction,
        [log: false, migration_lock: false] ++ opts
      )
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end
end
