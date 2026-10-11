defmodule Sacrum.Repo.WorkflowBundlesTest do
  use Sacrum.DataCase, async: true

  import Ecto.Query

  alias Sacrum.Repo.WorkflowBundles
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.{StepTransition, Workflow, WorkflowStep, WorkflowTransition}

  test "imports authored execute config and rejects runtime context or obsolete input" do
    {user, project} = create_project()

    config = %{
      "version" => 1,
      "script" => "transform(task)",
      "output_schema" => %{"type" => "object"}
    }

    bundle = %{
      "workflows" => [
        %{
          "workflow_ref" => "execute",
          "name" => "Execute",
          "steps" => [
            %{
              "step_ref" => "transform",
              "name" => "Transform",
              "step_type" => "execute",
              "config" => config
            }
          ]
        }
      ]
    }

    assert {:ok, result} = Sacrum.Accounts.WorkflowBundles.import(user.id, project.id, bundle)
    step = Repo.get!(WorkflowStep, get_in(result.step_mappings, ["execute", "transform"]))
    assert step.step_type == :execute
    assert step.harness == nil
    assert step.config.context == nil
    assert step.config.script == config["script"]
    assert step.config.output_schema == config["output_schema"]

    for key <- ["input", "context"], value <- [nil, %{}] do
      invalid =
        put_in(bundle, ["workflows", Access.at(0), "steps", Access.at(0), "config", key], value)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Sacrum.Accounts.WorkflowBundles.import(user.id, project.id, invalid)

      assert {message, _} = changeset.errors[:bundle]
      assert message == "workflows[0].steps[0].config.#{key}: is not supported for execute steps"
    end

    assert Repo.aggregate(from(w in Workflow, where: w.name == "Execute"), :count) == 1
  end

  test "imports workflows without changing the project's default" do
    {user, project} = create_project()

    assert {:ok, result} = WorkflowBundles.import(user.id, project.id, successful_bundle())

    assert result.workflow_count == 2
    assert result.step_count == 4
    assert result.step_edge_count == 2
    assert result.workflow_edge_count == 2
    assert Map.keys(result.workflow_mappings) |> Enum.sort() == ["build", "review"]

    workflows = Repo.all(from workflow in Workflow, where: workflow.project_id == ^project.id)
    steps = Repo.all(from step in WorkflowStep, where: step.project_id == ^project.id)

    assert length(workflows) == 3
    assert length(steps) == 5
    assert Enum.count(workflows, & &1.is_default) == 1
    assert Enum.find(workflows, &(&1.name == "Backlog")).is_default
    refute Enum.find(workflows, &(&1.name == "Build")).is_default
    assert Repo.aggregate(StepTransition, :count) == 2
    assert Repo.aggregate(WorkflowTransition, :count) == 2

    assert Enum.all?(result.workflows, &(&1.initial_step_id != nil))

    assert result.workflow_steps |> Enum.map(& &1.name) |> Enum.sort() == [
             "Build finish",
             "Build start",
             "Review done",
             "Review start"
           ]
  end

  test "rolls back imported rows and preserves the existing default after route failure" do
    {user, project} = create_project()

    [existing_default] =
      Repo.all(
        from workflow in Workflow,
          where: workflow.project_id == ^project.id and workflow.is_default
      )

    assert {:error, %Ecto.Changeset{}} =
             WorkflowBundles.import(user.id, project.id, invalid_route_bundle())

    assert Repo.get!(Workflow, existing_default.id).is_default

    assert Repo.all(
             from workflow in Workflow,
               where: workflow.project_id == ^project.id,
               select: workflow.name
           ) == ["Backlog"]

    assert Repo.all(
             from step in WorkflowStep, where: step.project_id == ^project.id, select: step.name
           ) == ["Backlog"]

    assert Repo.aggregate(StepTransition, :count) == 0
    assert Repo.aggregate(WorkflowTransition, :count) == 0
  end

  test "rejects a project outside the authenticated user scope" do
    {_owner, project} = create_project()
    {caller, _caller_project} = create_project()

    assert {:error, :not_found} =
             WorkflowBundles.import(caller.id, project.id, successful_bundle())
  end

  test "imports structured inference steps with their config" do
    {user, project} = create_project()

    assert {:ok, result} = WorkflowBundles.import(user.id, project.id, structured_bundle())

    step = Repo.get!(WorkflowStep, get_in(result.step_mappings, ["triage", "classify"]))

    assert step.step_type == :structured_inference
    assert step.config.provider == "typesafe"
    assert step.config.model == "system-one"
    assert step.config.state == %{"title" => "{{ task.title }}", "labels" => ["a", "b"]}
    assert step.config.questions == structured_questions()
  end

  test "imports nothing when a structured inference step is invalid" do
    {user, project} = create_project()

    bundle =
      update_in(
        structured_bundle(),
        ["workflows", Access.at(0), "steps", Access.at(0)],
        fn step ->
          put_in(step, ["config", "questions", "area", "criteria"], %{})
        end
      )

    assert {:error, %Ecto.Changeset{} = changeset} =
             WorkflowBundles.import(user.id, project.id, bundle)

    assert {"workflows[0].steps[0].config.questions.area.criteria: must be an object with 1 to 255 options",
            _opts} = changeset.errors[:bundle]

    assert Repo.all(
             from workflow in Workflow,
               where: workflow.project_id == ^project.id,
               select: workflow.name
           ) == ["Backlog"]
  end

  describe "step edge session directives" do
    test "imports step_ref and remaps it to the source step's id" do
      {user, project} = create_project()

      bundle =
        session_bundle([
          Map.put(step_edge("pair", "implement", "review"), "session", %{
            "mode" => "resume",
            "step_ref" => "implement"
          }),
          Map.put(step_edge("pair", "review", "fix"), "session", %{"mode" => "fork"}),
          step_edge("pair", "fix", "done")
        ])

      assert {:ok, result} = Sacrum.Accounts.WorkflowBundles.import(user.id, project.id, bundle)
      ids = result.step_mappings["pair"]

      sessions =
        Repo.all(
          from(t in StepTransition,
            where: t.from_step_id in ^Map.values(ids),
            select: {t.from_step_id, t.session}
          )
        )
        |> Map.new()

      assert sessions[ids["implement"]] == %{"mode" => "resume", "step_id" => ids["implement"]}
      assert sessions[ids["review"]] == %{"mode" => "fork"}
      assert sessions[ids["fix"]] == nil
    end

    test "rejects a persisted step_id, an unresolved step_ref and a bad mode at the edge path" do
      {user, project} = create_project()

      for {session, message} <- [
            {%{"mode" => "resume", "step_id" => Ecto.UUID.generate()},
             "step_edges[0].session.step_id: is not allowed"},
            {%{"mode" => "resume", "step_ref" => "missing"},
             "step_edges[0].session.step_ref: is not a known step ref"},
            {%{"mode" => "new", "step_ref" => "implement"},
             "step_edges[0].session.step_ref: is not allowed with mode new"},
            {%{"mode" => "continue"}, "step_edges[0].session.mode: must be new, resume, or fork"},
            {"resume", "step_edges[0].session: must be an object"}
          ] do
        bundle =
          session_bundle([
            Map.put(step_edge("pair", "implement", "review"), "session", session),
            step_edge("pair", "review", "fix"),
            step_edge("pair", "fix", "done")
          ])

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Sacrum.Accounts.WorkflowBundles.import(user.id, project.id, bundle)

        assert {^message, _} = changeset.errors[:bundle]
      end

      assert Repo.aggregate(
               from(w in Workflow, where: w.project_id == ^project.id and w.name == "Pair"),
               :count
             ) == 0
    end

    test "rejects a directive the graph cannot honor and imports nothing" do
      {user, project} = create_project()

      bundle =
        session_bundle([
          step_edge("pair", "implement", "review"),
          step_edge("pair", "review", "fix"),
          Map.put(step_edge("pair", "fix", "done"), "session", %{"mode" => "new"})
        ])

      assert {:error, %Ecto.Changeset{} = changeset} =
               Sacrum.Accounts.WorkflowBundles.import(user.id, project.id, bundle)

      assert {message, _} = changeset.errors[:bundle]
      assert message =~ "$.session: requires an llm_inference destination step"

      assert Repo.aggregate(
               from(w in Workflow, where: w.project_id == ^project.id and w.name == "Pair"),
               :count
             ) == 0
    end
  end

  describe "wait_children session directives" do
    test "imports step_ref and remaps it to the parent workflow step's id" do
      {user, project} = create_project()
      bundle = wait_children_bundle(%{"mode" => "fork", "step_ref" => "plan"})

      assert {:ok, result} = Sacrum.Accounts.WorkflowBundles.import(user.id, project.id, bundle)
      ids = result.step_mappings["parent"]

      assert Repo.get!(Sacrum.Repo.Schemas.WorkflowStep, ids["wait"]).config.session == %{
               "mode" => "fork",
               "step_id" => ids["plan"]
             }
    end

    test "rejects a persisted step_id, an unresolved step_ref, a missing step_ref and resume" do
      {user, project} = create_project()
      path = "workflows[0].steps[1].config.session"

      for {session, message} <- [
            {%{"mode" => "fork", "step_id" => Ecto.UUID.generate()},
             "#{path}.step_id: is not allowed"},
            {%{"mode" => "fork", "step_ref" => "missing"},
             "#{path}.step_ref: is not a known step ref"},
            {%{"mode" => "fork"}, "#{path}.step_ref: is required"},
            {%{"mode" => "resume", "step_ref" => "plan"}, "#{path}.mode: must be fork"},
            {"fork", "#{path}: must be an object"}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Sacrum.Accounts.WorkflowBundles.import(
                   user.id,
                   project.id,
                   wait_children_bundle(session)
                 )

        assert {^message, _} = changeset.errors[:bundle]
      end
    end

    test "rejects a fork of a step the graph cannot honor and imports nothing" do
      {user, project} = create_project()
      bundle = wait_children_bundle(%{"mode" => "fork", "step_ref" => "done"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Sacrum.Accounts.WorkflowBundles.import(user.id, project.id, bundle)

      assert {message, _} = changeset.errors[:bundle]
      assert message =~ "$.session.step_id: must be an llm_inference step in this workflow"

      assert Repo.aggregate(
               from(w in Workflow, where: w.project_id == ^project.id and w.name == "Parent"),
               :count
             ) == 0
    end
  end

  # plan -> wait -> done, where wait forks with `session`.
  defp wait_children_bundle(session) do
    %{
      "workflows" => [
        %{
          "workflow_ref" => "parent",
          "name" => "Parent",
          "initial_step" => address("parent", "plan"),
          "steps" => [
            %{
              "step_ref" => "plan",
              "name" => "plan",
              "step_type" => "llm_inference",
              "harness" => "codex"
            },
            %{
              "step_ref" => "wait",
              "name" => "wait",
              "step_type" => "wait_children",
              "harness" => "codex",
              "config" => %{"session" => session}
            },
            %{
              "step_ref" => "done",
              "name" => "done",
              "step_type" => "finish",
              "harness" => "codex"
            }
          ]
        }
      ],
      "step_edges" => [step_edge("parent", "plan", "wait"), step_edge("parent", "wait", "done")]
    }
  end

  defp session_bundle(step_edges) do
    llm = &%{"step_ref" => &1, "name" => &1, "step_type" => "llm_inference", "harness" => "codex"}

    %{
      "workflows" => [
        %{
          "workflow_ref" => "pair",
          "name" => "Pair",
          "initial_step" => address("pair", "implement"),
          "steps" => [
            llm.("implement"),
            llm.("review"),
            llm.("fix"),
            %{
              "step_ref" => "done",
              "name" => "done",
              "step_type" => "finish",
              "harness" => "codex"
            }
          ]
        }
      ],
      "step_edges" => step_edges
    }
  end

  defp create_project do
    suffix = Ecto.UUID.generate()

    {:ok, user} =
      Users.insert(%{
        email: "bundle-#{suffix}@example.com",
        username: "bundle#{String.slice(suffix, 0, 8)}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user.id, %{name: "Bundle #{suffix}"})
    {user, project}
  end

  defp successful_bundle do
    %{
      "workflows" => [
        %{
          "workflow_ref" => "build",
          "name" => "Build",
          "is_default" => true,
          "initial_step" => address("build", "start"),
          "steps" => [
            %{
              "step_ref" => "start",
              "name" => "Build start",
              "step_type" => "llm_inference",
              "harness" => "codex"
            },
            %{
              "step_ref" => "finish",
              "name" => "Build finish",
              "step_type" => "finish",
              "harness" => "codex"
            }
          ]
        },
        %{
          "workflow_ref" => "review",
          "name" => "Review",
          "initial_step" => address("review", "start"),
          "steps" => [
            %{
              "step_ref" => "start",
              "name" => "Review start",
              "step_type" => "llm_inference",
              "harness" => "codex"
            },
            %{
              "step_ref" => "done",
              "name" => "Review done",
              "step_type" => "finish",
              "harness" => "codex"
            }
          ]
        }
      ],
      "step_edges" => [
        step_edge("build", "start", "finish"),
        step_edge("review", "start", "done")
      ],
      "workflow_edges" => [
        workflow_edge("build", "review", "review", "start"),
        workflow_edge("review", "build", "build", "start")
      ]
    }
  end

  defp structured_bundle do
    %{
      "workflows" => [
        %{
          "workflow_ref" => "triage",
          "name" => "Triage",
          "initial_step" => address("triage", "classify"),
          "steps" => [
            %{
              "step_ref" => "classify",
              "name" => "Classify",
              "step_type" => "structured_inference",
              "harness" => "typesafe",
              "config" => %{
                "provider" => "typesafe",
                "model" => "system-one",
                "state" => %{"title" => "{{ task.title }}", "labels" => ["a", "b"]},
                "questions" => structured_questions()
              }
            },
            %{
              "step_ref" => "done",
              "name" => "Done",
              "step_type" => "finish",
              "harness" => "codex"
            }
          ]
        }
      ],
      "step_edges" => [step_edge("triage", "classify", "done")]
    }
  end

  defp structured_questions do
    %{
      "risky" => %{"type" => "noul", "instructions" => "Is the change risky?"},
      "area" => %{
        "type" => "choice",
        "instructions" => "Which area does it touch?",
        "criteria" => %{"api" => "Server code", "ui" => nil}
      },
      "size" => %{
        "type" => "score",
        "instructions" => "How large is it?",
        "criteria" => ["small", "medium", "large"]
      }
    }
  end

  defp invalid_route_bundle do
    %{
      "workflows" => [
        %{
          "workflow_ref" => "broken",
          "name" => "Broken Default",
          "is_default" => true,
          "initial_step" => address("broken", "route"),
          "steps" => [
            %{
              "step_ref" => "route",
              "name" => "Route",
              "step_type" => "route",
              "harness" => "codex",
              "config" => %{
                "route_config" => %{
                  "version" => 1,
                  "match_policy" => "exactly_one",
                  "rules" => [
                    %{
                      "id" => "done",
                      "when" => %{
                        "ref" => "previous_output.route.result",
                        "op" => "eq",
                        "value" => "done"
                      },
                      "transition" => %{"type" => "intra_workflow", "step_ref" => "finish"}
                    }
                  ],
                  "default" => %{
                    "transition" => %{"type" => "intra_workflow", "step_ref" => "finish"}
                  }
                }
              }
            },
            %{
              "step_ref" => "finish",
              "name" => "Finish",
              "step_type" => "finish",
              "harness" => "codex"
            }
          ]
        }
      ],
      "step_edges" => [step_edge("broken", "route", "finish")]
    }
  end

  defp address(workflow_ref, step_ref),
    do: %{"workflow_ref" => workflow_ref, "step_ref" => step_ref}

  defp step_edge(workflow_ref, from, to) do
    %{
      "from" => address(workflow_ref, from),
      "to" => address(workflow_ref, to)
    }
  end

  defp workflow_edge(
         from_workflow_ref,
         to_workflow_ref,
         destination_workflow_ref,
         destination_step_ref
       ) do
    %{
      "from_workflow_ref" => from_workflow_ref,
      "to_workflow_ref" => to_workflow_ref,
      "destination_step" => address(destination_workflow_ref, destination_step_ref)
    }
  end
end
