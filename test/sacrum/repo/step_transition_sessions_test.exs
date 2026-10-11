defmodule Sacrum.Repo.StepTransitionSessionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.RouteValidation
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Routing.RouteValidator

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "edge_sessions_#{suffix}@example.com",
        username: "edge_sessions_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Edge Sessions"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Main"})
    {:ok, other} = Accounts.Workflows.insert(user.id, project.id, %{name: "Other"})
    context = %{user: user, project: project, workflow: workflow}

    %{
      user: user,
      workflow: workflow,
      implement: create_step(context, "implement", 1),
      review: create_step(context, "review", 2),
      claude: create_step(context, "claude", 3, harness: "claude"),
      human: create_step(context, "human", 4, step_type: "human_input"),
      foreign: create_step(%{context | workflow: other}, "foreign", 1)
    }
  end

  describe "saving a step transition session" do
    test "accepts new, resume and fork and stores the canonical directive", context do
      for {session, stored} <- [
            {%{"mode" => "new"}, %{"mode" => "new"}},
            {%{"mode" => "resume"}, %{"mode" => "resume"}},
            {%{"mode" => "fork", "step_id" => context.implement.id},
             %{"mode" => "fork", "step_id" => context.implement.id}}
          ] do
        {:ok, transition} = insert(context, context.implement, context.review, session)
        assert transition.session == stored
        assert Repo.get!(StepTransition, transition.id).session == stored
        {:ok, _deleted} = Accounts.StepTransitions.delete(transition)
      end
    end

    test "an edge without a directive stores none", context do
      {:ok, transition} = insert(context, context.implement, context.review, nil)
      assert transition.session == nil
    end

    test "rejects malformed directives on the session field, naming the transition", context do
      name = "step transition #{context.implement.id} -> #{context.review.id}"

      for {session, message} <- [
            {%{"mode" => "continue"}, "$.session.mode: must be new, resume, or fork"},
            {%{"mode" => "new", "step_id" => context.implement.id},
             "$.session.step_id: is not allowed with mode new"},
            {%{"mode" => "resume", "name" => "impl"}, "$.session.name: is not allowed"},
            {%{"step_id" => context.implement.id}, "$.session.mode: is required"},
            {%{"mode" => "resume", "step_id" => "nope"}, "$.session.step_id: must be a UUID"},
            {"resume", "$.session: must be an object"},
            {%{mode: "new"}, "$.session: must use string keys"}
          ] do
        assert {:error, changeset} =
                 insert(context, context.implement, context.review, session)

        assert errors_on(changeset).session == ["#{name} #{message}"]
      end
    end

    test "rejects graph-invalid directives with the transition and session path", context do
      cases = [
        {context.implement, context.human, %{"mode" => "new"},
         "$.session: requires an llm_inference destination step"},
        {context.implement, context.review, %{"mode" => "resume", "step_id" => context.human.id},
         "$.session.step_id: must be an llm_inference step in this workflow"},
        {context.implement, context.review,
         %{"mode" => "resume", "step_id" => context.foreign.id},
         "$.session.step_id: must be an llm_inference step in this workflow"},
        {context.implement, context.review, %{"mode" => "fork", "step_id" => context.claude.id},
         "$.session.step_id: must use the same harness as the destination step"}
      ]

      for {from, to, session, message} <- cases do
        assert {:error, changeset} = insert(context, from, to, session)
        assert [error] = errors_on(changeset).session
        assert error =~ ~r/^step transition [0-9a-f-]{36} -> #{to.id} /
        assert String.ends_with?(error, message)
        refute Repo.get_by(StepTransition, from_step_id: from.id, to_step_id: to.id)
      end
    end

    test "rejects any directive on an edge leaving a route step", context do
      source =
        create_step(context, "source", 5, config: %{"output_schema" => verdict_schema()})

      route =
        create_step(context, "route", 6,
          step_type: "route",
          config: %{"route_config" => route_config(context.review.id)}
        )

      {:ok, _incoming} = insert(context, source, route, nil)

      assert {:error, changeset} = insert(context, route, context.review, %{"mode" => "new"})

      assert [error] = errors_on(changeset).session

      assert error =~
               "$.session: is not allowed on a transition leaving a route step; route decisions carry the session"
    end
  end

  describe "syncStepTransitions" do
    test "creates, updates and clears edge directives", context do
      resume = %{"mode" => "resume", "step_id" => context.implement.id}

      assert {:ok, [transition]} =
               Accounts.WorkflowSteps.sync_transitions(context.implement, [
                 %{to_step_id: context.review.id, label: "next", session: resume}
               ])

      assert transition.session == resume

      assert {:ok, [updated]} =
               Accounts.WorkflowSteps.sync_transitions(context.implement, [
                 %{"to_step_id" => context.review.id, "session" => %{"mode" => "fork"}}
               ])

      assert updated.id == transition.id
      assert updated.session == %{"mode" => "fork"}
      assert updated.label == nil

      assert {:ok, [cleared]} =
               Accounts.WorkflowSteps.sync_transitions(context.implement, [
                 %{to_step_id: context.review.id}
               ])

      assert cleared.id == transition.id
      assert cleared.session == nil
    end

    test "rejects an invalid directive and keeps the stored one", context do
      {:ok, transition} = insert(context, context.implement, context.review, %{"mode" => "new"})

      assert {:error, changeset} =
               Accounts.WorkflowSteps.sync_transitions(context.implement, [
                 %{
                   to_step_id: context.review.id,
                   session: %{"mode" => "resume", "step_id" => context.claude.id}
                 }
               ])

      assert [error] = errors_on(changeset).session
      assert error =~ "step transition #{context.implement.id} -> #{context.review.id}"
      assert error =~ "$.session.step_id: must use the same harness as the destination step"
      assert Repo.get!(StepTransition, transition.id).session == %{"mode" => "new"}
    end
  end

  describe "graph edits" do
    test "reject a step change that breaks an edge directive", context do
      {:ok, _transition} =
        insert(context, context.implement, context.review, %{
          "mode" => "resume",
          "step_id" => context.implement.id
        })

      assert {:error, changeset} =
               Accounts.WorkflowSteps.update(context.implement, %{"harness" => "claude"})

      assert [error] = errors_on(changeset).session
      assert error =~ "$.session.step_id: must use the same harness as the destination step"
    end

    test "runtime loading proves stored edge directives", context do
      {:ok, transition} = insert(context, context.implement, context.review, %{"mode" => "new"})

      {:ok, _transition} =
        transition
        |> Ecto.Changeset.change(session: %{"mode" => "resume", "step_id" => context.human.id})
        |> Repo.update()

      {:ok, snapshot} = RouteValidation.load_snapshot(context.workflow.id)

      assert {:error,
              %{
                code: :step_transition_session_invalid,
                path: "$.session.step_id",
                transition_id: transition_id
              }} = RouteValidator.validate_snapshot(snapshot, [context.workflow.id])

      assert transition_id == transition.id
    end
  end

  defp insert(context, from, to, session) do
    attrs = %{from_step_id: from.id, to_step_id: to.id, project_id: from.project_id}
    attrs = if is_nil(session), do: attrs, else: Map.put(attrs, :session, session)
    Accounts.StepTransitions.insert(context.user.id, attrs)
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

  defp route_config(step_id) do
    target = %{"type" => "intra_workflow", "step_id" => step_id}

    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "tickets",
          "when" => %{"ref" => "task.level", "op" => "eq", "value" => "ticket"},
          "transition" => target
        }
      ],
      "default" => %{"transition" => target}
    }
  end

  defp verdict_schema do
    %{
      "type" => "object",
      "properties" => %{"verdict" => %{"type" => "string", "enum" => ["ready"]}},
      "required" => ["verdict"],
      "additionalProperties" => false
    }
  end
end
