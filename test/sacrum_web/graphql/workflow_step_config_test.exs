defmodule SacrumWeb.Graphql.WorkflowStepConfigTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts

  @config_fields """
  stepType
  config {
    __typename
    ... on LlmInferenceStepConfig { version prompt agents skills agentConfig outputSchema }
    ... on WaitChildrenStepConfig { version outputSchema }
  }
  """

  @execute_fields """
  id harness stepType
  config { __typename ... on ExecuteStepConfig { version script context outputSchema } }
  """

  setup do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Config Project"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Config"})
    %{user: user, workflow: workflow}
  end

  test "execute create/read/update round-trips authored config without input or a harness",
       %{conn: conn, user: user, workflow: workflow} do
    config = %{
      "version" => 1,
      "script" => "transform(execution.previous_output)",
      "output_schema" => %{"type" => "object"}
    }

    created =
      conn
      |> authenticate(user)
      |> graphql("""
      mutation { createWorkflowStep(workflowId: "#{workflow.id}", name: "transform", stepType: "execute", config: #{json_arg(config)}) { #{@execute_fields} } }
      """)
      |> json_response(200)

    refute created["errors"]
    step = created["data"]["createWorkflowStep"]
    assert step["harness"] == nil
    assert step["stepType"] == "execute"

    assert step["config"] == %{
             "__typename" => "ExecuteStepConfig",
             "version" => 1,
             "script" => config["script"],
             "context" => nil,
             "outputSchema" => %{"type" => "object"}
           }

    read =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      query { workflowStep(id: "#{step["id"]}") { #{@execute_fields} } }
      """)
      |> json_response(200)

    assert read["data"]["workflowStep"] == step

    updated =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation { updateWorkflowStep(id: "#{step["id"]}", config: #{json_arg(%{"script" => "changed"})}) { #{@execute_fields} } }
      """)
      |> json_response(200)

    refute updated["errors"]

    assert updated["data"]["updateWorkflowStep"]["config"] ==
             Map.put(step["config"], "script", "changed")

    for key <- ["input", "context"] do
      result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
        mutation { updateWorkflowStep(id: "#{step["id"]}", config: #{json_arg(%{key => nil})}) { id } }
        """)
        |> json_response(200)

      assert [%{"message" => message}] = result["errors"]
      assert message == "config: $.#{key}: is not supported for execute steps"
    end
  end

  test "execute rejects obsolete input, authored context, provider config, and harness",
       %{conn: conn, user: user, workflow: workflow} do
    config = %{"script" => "transform(task)", "output_schema" => %{"type" => "null"}}

    for {harness_arg, supplied_config, message} <- [
          {"harness: \"codex\"", config, "harness: must be null for execute steps"},
          {"", Map.put(config, "provider", "openai"),
           "config: $.provider: is not supported for execute steps"},
          {"", Map.put(config, "input", nil),
           "config: $.input: is not supported for execute steps"},
          {"", Map.put(config, "context", %{}),
           "config: $.context: is not supported for execute steps"}
        ] do
      result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
        mutation { createWorkflowStep(workflowId: "#{workflow.id}", name: "bad", stepType: "execute", #{harness_arg} config: #{json_arg(supplied_config)}) { id } }
        """)
        |> json_response(200)

      assert [%{"message" => ^message}] = result["errors"]
    end

    result =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation { createWorkflowStep(workflowId: "#{workflow.id}", name: "inference", stepType: "llm_inference") { id } }
      """)
      |> json_response(200)

    assert [%{"message" => "harness: can't be blank"}] = result["errors"]
  end

  test "execution context snapshot is readable and separate from mutable route audit context",
       %{conn: conn, user: user, workflow: workflow} do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(workflow, %{
        name: "Execute",
        step_type: "execute",
        config: %{"script" => "transform(task)", "output_schema" => %{"type" => "object"}}
      })

    {:ok, task} =
      Accounts.Tasks.insert(user.id, workflow.project_id, %{title: "T", level: "task"})

    context = %{
      "task" => %{"title" => "T"},
      "execution" => %{"previous_output" => false},
      "inputs" => %{"nothing" => nil},
      "steps" => %{},
      "workflow" => %{},
      "artifacts" => %{}
    }

    execution =
      %Sacrum.Repo.Schemas.StepExecution{user_id: user.id, project_id: task.project_id}
      |> Sacrum.Repo.Schemas.StepExecution.create_changeset(%{
        task_id: task.id,
        step_id: step.id,
        step_type: :execute,
        step_name: step.name,
        status: "started"
      })
      |> Sacrum.Repo.Schemas.StepExecution.put_config(%{step.config | context: context})
      |> Sacrum.Repo.insert!()

    read =
      conn
      |> authenticate(user)
      |> graphql("""
      query { stepExecution(id: "#{execution.id}") { context config { ... on ExecuteStepConfig { context script } } } }
      """)
      |> json_response(200)

    assert read["data"]["stepExecution"] == %{
             "context" => %{},
             "config" => %{"context" => context, "script" => step.config.script}
           }

    audit = %{"route" => "changed"}

    updated =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation { updateStepExecution(id: "#{execution.id}", context: #{json_arg(audit)}) { context config { ... on ExecuteStepConfig { context } } } }
      """)
      |> json_response(200)

    assert updated["data"]["updateStepExecution"] == %{
             "context" => audit,
             "config" => %{"context" => context}
           }

    rejected =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation { updateStepExecution(id: "#{execution.id}", config: #{json_arg(%{"context" => %{}})}) { id } }
      """)
      |> json_response(200)

    assert [%{"message" => message}] = rejected["errors"]
    assert message =~ "Unknown argument \"config\""

    assert Sacrum.Repo.get!(Sacrum.Repo.Schemas.StepExecution, execution.id).config.context ===
             context
  end

  test "createWorkflowStep accepts a typed config and exposes it",
       %{conn: conn, user: user, workflow: workflow} do
    config = %{"prompt" => "Implement {{ task.title }}", "agents" => ["implementer"]}

    result =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          createWorkflowStep(
            harness: "codex"
            workflowId: "#{workflow.id}"
            name: "Implement"
            stepType: "llm_inference"
            config: #{json_arg(config)}
          ) { #{@config_fields} }
        }
      """)
      |> json_response(200)

    assert result["data"]["createWorkflowStep"] == %{
             "stepType" => "llm_inference",
             "config" => %{
               "__typename" => "LlmInferenceStepConfig",
               "version" => 1,
               "prompt" => "Implement {{ task.title }}",
               "agents" => ["implementer"],
               "skills" => [],
               "agentConfig" => %{},
               "outputSchema" => nil
             }
           }
  end

  test "updateWorkflowStep patches the config and rejects a step type change",
       %{conn: conn, user: user, workflow: workflow} do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(
        workflow,
        workflow_step_attrs(%{
          name: "Implement",
          harness: "claude",
          config: %{"prompt" => "Go", "output_schema" => %{"type" => "object"}}
        })
      )

    patched =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          updateWorkflowStep(id: "#{step.id}", config: #{json_arg(%{"agents" => ["worker"]})}) {
            #{@config_fields}
          }
        }
      """)
      |> json_response(200)

    assert %{
             "stepType" => "llm_inference",
             "config" => %{
               "prompt" => "Go",
               "outputSchema" => %{"type" => "object"},
               "agents" => ["worker"]
             }
           } = patched["data"]["updateWorkflowStep"]

    retyped =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
        mutation {
          updateWorkflowStep(id: "#{step.id}", stepType: "wait_children") { id }
        }
      """)
      |> json_response(200)

    assert [%{"message" => "step_type: cannot be changed; create a new step instead"}] =
             retyped["errors"]
  end

  test "config errors are path-aware and null-config steps expose null",
       %{conn: conn, user: user, workflow: workflow} do
    rejected =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          createWorkflowStep(
            harness: "codex"
            workflowId: "#{workflow.id}"
            name: "Bad"
            stepType: "llm_inference"
            config: #{json_arg(%{"temperature" => 1})}
          ) { id }
        }
      """)
      |> json_response(200)

    assert [%{"message" => "config: $.temperature: is not supported for llm_inference steps"}] =
             rejected["errors"]

    gate =
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          createWorkflowStep(workflowId: "#{workflow.id}", name: "Gate", stepType: "human_input", harness: "codex") {
            stepType config { __typename }
          }
        }
      """)
      |> json_response(200)

    assert gate["data"]["createWorkflowStep"] == %{"stepType" => "human_input", "config" => nil}
  end

  defp graphql(conn, query), do: post(conn, "/graphql", %{"query" => query})

  defp json_arg(value), do: Jason.encode!(Jason.encode!(value))

  test "step executions expose the config they ran with and no prompt",
       %{conn: conn, user: user, workflow: workflow} do
    questions = %{"ok" => %{"type" => "noul", "instructions" => "Is it ok?"}}

    {:ok, step} =
      Accounts.WorkflowSteps.insert(
        workflow,
        workflow_step_attrs(%{
          name: "Judge",
          step_type: "structured_inference",
          config: %{
            "provider" => "typesafe",
            "model" => "jev",
            "state" => "x",
            "questions" => questions
          }
        })
      )

    {:ok, task} =
      Accounts.Tasks.insert(user.id, workflow.project_id, %{title: "T", level: "task"})

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, %{
        task_id: task.id,
        project_id: task.project_id,
        step_id: step.id,
        step_name: step.name,
        status: "started"
      })

    authed = authenticate(conn, user)

    result =
      authed
      |> graphql("""
        mutation {
          updateStepExecution(id: "#{execution.id}", status: "in_progress") {
            config {
              __typename
              ... on StructuredInferenceStepConfig { version provider model state questions }
            }
          }
        }
      """)
      |> json_response(200)

    assert result["data"]["updateStepExecution"]["config"] == %{
             "__typename" => "StructuredInferenceStepConfig",
             "version" => 1,
             "provider" => "typesafe",
             "model" => "jev",
             "state" => "x",
             "questions" => questions
           }

    result =
      authed
      |> graphql("""
        mutation { updateStepExecution(id: "#{execution.id}", prompt: "x") { id } }
      """)
      |> json_response(200)

    assert [%{"message" => message}] = result["errors"]
    assert message =~ "Unknown argument \"prompt\""
  end

  test "llm_inference config rejects session; route decisions carry it and executions expose conversations",
       %{conn: conn, user: user, workflow: workflow} do
    rejected =
      conn
      |> authenticate(user)
      |> graphql("""
      mutation { createWorkflowStep(workflowId: "#{workflow.id}", name: "bad", stepType: "llm_inference", harness: "codex", config: #{json_arg(%{"prompt" => "x", "session" => %{"name" => "impl", "mode" => "new"}})}) { id } }
      """)
      |> json_response(200)

    assert [%{"message" => message}] = rejected["errors"]
    assert message =~ "session: is not supported for llm_inference steps"

    {:ok, implement} =
      Accounts.WorkflowSteps.insert(
        user.id,
        workflow_step_attrs(%{
          "name" => "implement",
          "workflow_id" => workflow.id,
          "project_id" => workflow.project_id,
          "config" => %{"prompt" => "Implement"}
        })
      )

    {:ok, review} =
      Accounts.WorkflowSteps.insert(
        user.id,
        workflow_step_attrs(%{
          "name" => "review",
          "workflow_id" => workflow.id,
          "project_id" => workflow.project_id,
          "config" => %{"prompt" => "Review", "output_schema" => review_schema()}
        })
      )

    route_config = fn session ->
      %{
        "version" => 1,
        "match_policy" => "exactly_one",
        "rules" => [
          %{
            "id" => "ticket",
            "when" => %{"ref" => "task.level", "op" => "eq", "value" => "ticket"},
            "transition" => %{"type" => "intra_workflow", "step_id" => implement.id},
            "session" => session
          }
        ],
        "default" => %{"transition" => %{"type" => "intra_workflow", "step_id" => implement.id}}
      }
    end

    resume = %{"mode" => "resume"}

    created =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation { createWorkflowStep(workflowId: "#{workflow.id}", name: "route", stepType: "route", harness: "codex", config: #{json_arg(%{"route_config" => route_config.(resume)})}) { id config { ... on RouteStepConfig { routeConfig } } } }
      """)
      |> json_response(200)

    refute created["errors"]
    route = created["data"]["createWorkflowStep"]
    assert route["config"]["routeConfig"] == route_config.(resume)

    for {from, to} <- [{review.id, route["id"]}, {route["id"], implement.id}] do
      {:ok, _transition} =
        Accounts.StepTransitions.insert(user.id, %{
          "from_step_id" => from,
          "to_step_id" => to,
          "project_id" => workflow.project_id
        })
    end

    fork = %{"mode" => "fork", "step_id" => implement.id}

    updated =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation { updateWorkflowStep(id: "#{route["id"]}", config: #{json_arg(%{"route_config" => route_config.(fork)})}) { config { ... on RouteStepConfig { routeConfig } } } }
      """)
      |> json_response(200)

    refute updated["errors"]
    assert updated["data"]["updateWorkflowStep"]["config"]["routeConfig"] == route_config.(fork)

    invalid =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation { updateWorkflowStep(id: "#{route["id"]}", config: #{json_arg(%{"route_config" => route_config.(%{"mode" => "new", "step_id" => implement.id})})}) { id } }
      """)
      |> json_response(200)

    assert [%{"message" => message}] = invalid["errors"]
    assert message =~ "$.rules[0].session.step_id: is not allowed with mode new"

    {:ok, task} =
      Accounts.Tasks.insert(user.id, workflow.project_id, %{title: "Session", level: "ticket"})

    source =
      %Sacrum.Repo.Schemas.StepExecution{
        user_id: user.id,
        project_id: workflow.project_id,
        task_id: task.id,
        workflow_id: workflow.id,
        step_id: implement.id,
        step_name: "implement",
        status: "completed"
      }
      |> Sacrum.Repo.insert!()

    execution =
      %Sacrum.Repo.Schemas.StepExecution{
        user_id: user.id,
        project_id: workflow.project_id,
        task_id: task.id,
        workflow_id: workflow.id,
        step_id: implement.id,
        step_name: "implement",
        status: "started",
        resume_session_id: "native-0",
        forked_from_execution_id: source.id
      }
      |> Sacrum.Repo.insert!()

    execution =
      execution
      |> Ecto.Changeset.change(conversation_root_execution_id: execution.id)
      |> Sacrum.Repo.update!()

    reported =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      mutation { updateStepExecution(id: "#{execution.id}", nativeSessionId: "native-1") { resumeSessionId nativeSessionId conversationRootExecutionId forkedFromExecutionId } }
      """)
      |> json_response(200)

    assert reported["data"]["updateStepExecution"] == %{
             "resumeSessionId" => "native-0",
             "nativeSessionId" => "native-1",
             "conversationRootExecutionId" => execution.id,
             "forkedFromExecutionId" => source.id
           }

    for field <- ["sessionName", "conversationRootExecutionId"] do
      forged =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
        mutation { updateStepExecution(id: "#{execution.id}", #{field}: "forged") { id } }
        """)
        |> json_response(200)

      assert [%{"message" => message}] = forged["errors"]
      assert message =~ "Unknown argument \"#{field}\""
    end

    dropped =
      conn
      |> recycle()
      |> authenticate(user)
      |> graphql("""
      query { stepExecutions(taskId: "#{task.id}") { sessionName } }
      """)
      |> json_response(200)

    assert [%{"message" => message}] = dropped["errors"]
    assert message =~ "Cannot query field \"sessionName\""
  end

  defp review_schema do
    %{
      "type" => "object",
      "properties" => %{"summary" => %{"type" => "string"}},
      "required" => ["summary"],
      "additionalProperties" => false
    }
  end
end
