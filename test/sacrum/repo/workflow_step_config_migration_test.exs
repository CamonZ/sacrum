defmodule Sacrum.Repo.WorkflowStepConfigMigrationTest do
  @moduledoc """
  Rolls the config migrations back inside the sandbox transaction, seeds one
  row per pre-config step shape through the legacy columns, and migrates
  forward again. The DDL is transactional, so the sandbox rollback restores
  the schema for other tests.
  """

  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Realtime.CommandBroadcaster
  alias Sacrum.Repo.Schemas.{Task, TaskWorkspace, WorkflowStep}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Repo.Schemas.WorkflowStep.Config.{LlmInference, Route, WaitChildren}
  alias Sacrum.Repo.Users
  alias Sacrum.Routing.{Contract, RouteMode}

  @expand_version 20_260_923_120_000

  @output_schema %{
    "type" => "object",
    "properties" => %{"result" => %{"type" => "string"}},
    "required" => ["result"],
    "additionalProperties" => false
  }

  @route_config %{
    "version" => 1,
    "match_policy" => "exactly_one",
    "rules" => [
      %{
        "id" => "approved",
        "when" => %{"ref" => "task.level", "op" => "eq", "value" => "task"},
        "transition" => %{"type" => "intra_workflow", "step_id" => Ecto.UUID.generate()}
      }
    ]
  }

  @inference %{
    prompt: "Do the work for {{ task.title }}",
    output_schema: @output_schema,
    agents: ["implementer"],
    skills: ["elixir"],
    agent_config: %{"provider" => "claude", "model" => "opus"}
  }

  # One entry per pre-config workflow step shape: legacy columns in, the
  # expected step_type and config out.
  @shapes [
    execute:
      {Map.put(@inference, :step_type, "execute"), :llm_inference,
       %LlmInference{
         prompt: @inference.prompt,
         output_schema: @output_schema,
         agents: ["implementer"],
         skills: ["elixir"],
         agent_config: %{"provider" => "claude", "model" => "opus"}
       }},
    evaluate:
      {%{step_type: "evaluate", prompt: "Review it", agents: [], skills: [], agent_config: nil},
       :llm_inference, %LlmInference{prompt: "Review it", agent_config: nil}},
    prompt_route:
      {%{
         step_type: "route",
         prompt: "Pick the next step",
         output_schema: Contract.output_schema(),
         agents: ["router"],
         skills: [],
         agent_config: %{}
       }, :route, %Route{}},
    configured_route:
      {%{
         step_type: "route",
         route_config: @route_config,
         agents: [],
         skills: [],
         agent_config: %{}
       }, :route, %Route{route_config: @route_config}},
    human_input:
      {%{
         step_type: "human_input",
         prompt: "Approve?",
         output_schema: @output_schema,
         agents: ["x"]
       }, :human_input, nil},
    wait_children:
      {%{step_type: "wait_children", output_schema: @output_schema, agent_config: %{"a" => 1}},
       :wait_children, %WaitChildren{output_schema: @output_schema}},
    stop: {%{step_type: "stop", prompt: "ignored", agents: ["x"]}, :stop, nil},
    finish: {%{step_type: "finish"}, :finish, nil}
  ]

  setup do
    {:ok, user} =
      Users.insert(%{email: "migrate@example.com", username: "migrate", password: "password123"})

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Migration"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Legacy"})

    %{workflow: workflow}
  end

  test "every legacy step shape migrates into its config variant and behaves as before",
       %{workflow: workflow} do
    migrate(:down, @expand_version)

    ids =
      Map.new(@shapes, fn {name, {legacy, _type, _config}} ->
        {name, insert_legacy(workflow, legacy)}
      end)

    migrate(:up)

    for {name, {legacy, step_type, config}} <- @shapes do
      step = Repo.get!(WorkflowStep, ids[name])

      assert {name, step.step_type, step.config} == {name, step_type, config}

      # The migrated row already satisfies the closed variant.
      assert %Ecto.Changeset{valid?: true, changes: changes} =
               WorkflowStep.update_changeset(step, %{})

      assert changes == %{}, "#{name} changed on re-cast: #{inspect(changes)}"

      # Casting the same legacy shape through today's write path agrees.
      created = WorkflowStep.create_changeset(%WorkflowStep{}, created_attrs(legacy, step_type))
      assert created.valid?, "#{name}: #{inspect(created.errors)}"
      assert get_field(created, :config) == config
    end

    assert_daemon_payload(Repo.get!(WorkflowStep, ids.execute), @inference)
    assert_daemon_payload(Repo.get!(WorkflowStep, ids.evaluate), %{prompt: "Review it"})

    # Route prompts are no longer used, so a prompt-only route is unconfigured.
    assert {:error, :route_config_required} =
             RouteMode.routing_mode(Repo.get!(WorkflowStep, ids.prompt_route))

    assert {:ok, {:deterministic, %{version: 1}}} =
             RouteMode.routing_mode(Repo.get!(WorkflowStep, ids.configured_route))
  end

  test "rolling back restores the legacy columns from config", %{workflow: workflow} do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(workflow, %{
        name: "Implement",
        step_type: "llm_inference",
        config: %{"prompt" => "Go", "output_schema" => @output_schema, "agents" => ["a"]}
      })

    {:ok, route} =
      Accounts.WorkflowSteps.insert(workflow, %{name: "Route", step_type: "route"})

    migrate(:down, @expand_version + 100)

    assert %{rows: rows} =
             Repo.query!(
               """
               SELECT step_type, prompt, output_schema, agents, skills, agent_config, route_config
               FROM workflow_steps WHERE id = ANY($1) ORDER BY step_order NULLS FIRST, name
               """,
               [[Ecto.UUID.dump!(step.id), Ecto.UUID.dump!(route.id)]]
             )

    assert rows == [
             ["llm_inference", "Go", @output_schema, ["a"], [], %{}, nil],
             ["route", nil, nil, [], [], %{}, nil]
           ]

    migrate(:up)
    assert Repo.get!(WorkflowStep, step.id).config == step.config
  end

  # The migrator holds its lock in the caller while running each migration in
  # a task; the sandbox has one shared connection, so the lock must be off.
  defp migrate(:down, version), do: run_migrations(:down, to: version)
  defp migrate(:up), do: run_migrations(:up, all: true)

  defp run_migrations(direction, opts) do
    # Loading already-compiled migration files again would warn per module.
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(
        Repo,
        migrations_path(),
        direction,
        [log: false, migration_lock: false] ++ opts
      )
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  defp migrations_path, do: Application.app_dir(:sacrum, "priv/repo/migrations")

  defp insert_legacy(workflow, legacy) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO workflow_steps
        (id, workflow_id, user_id, project_id, name, step_type, prompt, output_schema,
         agents, skills, agent_config, route_config, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(workflow.id),
        Ecto.UUID.dump!(workflow.user_id),
        Ecto.UUID.dump!(workflow.project_id),
        "legacy #{legacy.step_type}",
        legacy.step_type,
        legacy[:prompt],
        legacy[:output_schema],
        Map.get(legacy, :agents, []),
        Map.get(legacy, :skills, []),
        Map.get(legacy, :agent_config, %{}),
        legacy[:route_config],
        now
      ]
    )

    id
  end

  # The legacy columns the step type declares, sent as its config.
  defp created_attrs(legacy, step_type) do
    config =
      with module when not is_nil(module) <- Config.module(step_type) do
        for {key, value} <- Map.take(legacy, module.__schema__(:fields)),
            into: %{},
            do: {"#{key}", value}
      end

    %{name: "created #{step_type}", step_type: step_type, config: config}
  end

  # The daemon-facing run payload built from the migrated step matches the one
  # the legacy columns produced.
  defp assert_daemon_payload(step, legacy) do
    daemon_id = Ecto.UUID.generate()
    Phoenix.PubSub.subscribe(Sacrum.PubSub, "daemon:#{daemon_id}")

    execution = %{
      id: Ecto.UUID.generate(),
      task_id: Ecto.UUID.generate(),
      project_id: step.project_id,
      config: step.config
    }

    data = %{
      execution: execution,
      step: step,
      task: %Task{workspace: %TaskWorkspace{daemon_id: daemon_id, worktree_path: "/tmp/wt"}}
    }

    assert :ok = CommandBroadcaster.broadcast_run_step(data, daemon_id)
    assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}

    expected =
      %{
        id: execution.id,
        task_id: execution.task_id,
        project_id: step.project_id,
        prompt: legacy.prompt || "",
        agent_config: Map.get(legacy, :agent_config),
        worktree: "/tmp/wt"
      }
      |> then(
        &if(legacy[:output_schema],
          do: Map.put(&1, :output_schema, legacy.output_schema),
          else: &1
        )
      )

    assert payload == expected
  end
end
