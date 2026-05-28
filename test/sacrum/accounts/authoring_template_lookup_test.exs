defmodule Sacrum.Accounts.AuthoringTemplateLookupTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{AuthoringTemplateLookup, Projects}
  alias Sacrum.Repo.AuthoringTemplates
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Users

  @request %{
    run_kind: "goal_exploration",
    artifact_type: "workflow_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_goal_exploration"
  }
  @code_factory_request %{
    run_kind: "code_factory",
    artifact_type: "workflow_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_code_factory_creation"
  }

  defp create_user(prefix) do
    suffix = System.unique_integer([:positive])

    username_prefix =
      prefix
      |> String.replace("-", "_")
      |> String.slice(0, 20)

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{username_prefix}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user, name) do
    {:ok, project} = Projects.insert(user.id, %{name: name})
    project
  end

  defp lookup_context(user, project), do: %{user_id: user.id, project_id: project.id}

  defp insert_template!(attrs) do
    attrs =
      @request
      |> Map.merge(%{
        name: "default",
        payload: %{
          "sections" => [%{"kind" => "goal", "title" => "Goal"}],
          "validation_policy" => %{"required_sections" => ["goal"]}
        }
      })
      |> Map.merge(Map.new(attrs))

    {:ok, template} = AuthoringTemplates.insert(attrs)
    template
  end

  describe "get_template/2" do
    test "resolves the most specific project template for a run, artifact, kind, and state-machine request" do
      user = create_user("authoring-template-lookup")
      project = create_project(user, "Authoring Template Lookup")

      insert_template!(
        name: "app-default",
        payload: %{
          "scope" => %{"project_id" => nil},
          "sections" => [%{"kind" => "goal", "title" => "Default goal"}],
          "validation_policy" => %{"required_sections" => ["goal"]}
        }
      )

      scoped = %{
        "scope" => %{"project_id" => project.id},
        "sections" => [
          %{"kind" => "goal", "title" => "Project goal"},
          %{"kind" => "constraints", "title" => "Project constraints"}
        ],
        "starter_draft" => %{"title" => "Project-specific discovery draft"},
        "validation_policy" => %{"required_sections" => ["goal", "constraints"]}
      }

      insert_template!(name: "project-specific", payload: scoped)

      assert {:ok, template} =
               AuthoringTemplateLookup.get_template(lookup_context(user, project), @request)

      assert template == %{
               run_kind: "goal_exploration",
               artifact_type: "workflow_draft",
               template_kind: "starter_draft",
               state_machine_entrypoint: "start_goal_exploration",
               name: "project-specific",
               payload: scoped
             }
    end

    test "returns the deterministic app-scoped template when no project-specific record exists" do
      user = create_user("authoring-template-fallback")
      project = create_project(user, "Authoring Template Fallback")

      insert_template!(
        name: "zz-secondary-default",
        payload: %{
          "scope" => %{"project_id" => nil},
          "starter_draft" => %{"title" => "Secondary default"},
          "validation_policy" => %{"required_sections" => ["goal"]}
        }
      )

      fallback_payload = %{
        "scope" => %{"project_id" => nil},
        "starter_draft" => %{"title" => "Primary default"},
        "validation_policy" => %{"required_sections" => ["goal"]}
      }

      insert_template!(name: "aa-primary-default", payload: fallback_payload)

      assert {:ok, template} =
               AuthoringTemplateLookup.get_template(lookup_context(user, project), @request)

      assert template.name == "aa-primary-default"
      assert template.payload == fallback_payload
    end

    test "returns not found when no persisted template matches the request" do
      user = create_user("authoring-template-missing")
      project = create_project(user, "Missing Authoring Template")

      assert {:error, :not_found} =
               AuthoringTemplateLookup.get_template(lookup_context(user, project), @request)
    end

    test "composes code-factory workflow recipe and prompt templates into the starter draft" do
      user = create_user("authoring-template-code-factory")
      project = create_project(user, "Composed Code Factory Templates")

      insert_code_factory_template!(%{
        template_kind: "starter_draft",
        name: "project_code_factory_creation",
        payload: %{
          "scope" => %{"project_id" => project.id},
          "apply_target" => "workflow_bundle",
          "validation_expectations" => ["Starter expectations remain present."]
        }
      })

      insert_code_factory_template!(%{
        template_kind: "workflow_recipe",
        name: "project_code_factory_workflows",
        payload: %{
          "scope" => %{"project_id" => project.id},
          "validation_expectations" => ["Route steps emit schema-constrained transition output."],
          "workflows" => [
            %{
              "key" => "implementation",
              "steps" => [
                %{"key" => "implement", "type" => "work"},
                %{
                  "key" => "route",
                  "type" => "route",
                  "output_schema" => WorkflowStep.routing_contract_schema(),
                  "transitions_to" => ["verification.review"]
                }
              ]
            }
          ],
          "transitions" => [
            %{
              "from" => "implementation",
              "to" => "verification",
              "label" => "ready_for_review",
              "target_step" => "verification.review"
            }
          ]
        }
      })

      insert_code_factory_template!(%{
        template_kind: "prompt_template",
        name: "project_code_factory_step_prompts",
        payload: %{
          "scope" => %{"project_id" => project.id},
          "rules" => %{
            "guard_variables" => "Guard every optional variable or section before printing it.",
            "schema_directive" =>
              "Eval and route prompts must ask for JSON matching workflow.output_schema."
          },
          "prompts" => [
            %{
              "workflow" => "implementation",
              "step" => "implement",
              "requires_output_schema_directive" => false,
              "template" =>
                "{% if task.desired_behavior %}Implement {{ task.desired_behavior }}.{% endif %}"
            },
            %{
              "workflow" => "implementation",
              "step" => "route",
              "requires_output_schema_directive" => true,
              "template" =>
                "{% if workflow.output_schema %}Output JSON matching {{ workflow.output_schema }}.{% endif %}"
            }
          ]
        }
      })

      assert {:ok, template} =
               AuthoringTemplateLookup.get_template(
                 lookup_context(user, project),
                 @code_factory_request
               )

      assert %{"workflows" => [workflow], "transitions" => [_transition]} = template.payload
      assert workflow["key"] == "implementation"

      assert [%{"prompt" => implement_prompt}, %{"output_schema" => route_schema} = route_step] =
               workflow["steps"]

      assert String.contains?(implement_prompt, "{% if task.desired_behavior %}")
      assert route_step["prompt"] =~ "{{ workflow.output_schema }}"
      assert route_schema == WorkflowStep.routing_contract_schema()
      assert template.payload["rules"]["guard_variables"] =~ "Guard every optional variable"

      assert "Route steps emit schema-constrained transition output." in template.payload[
               "validation_expectations"
             ]
    end
  end

  describe "authenticated project boundary" do
    test "rejects other-user project context before returning template payloads" do
      owner = create_user("authoring-template-owner")
      intruder = create_user("authoring-template-intruder")
      project = create_project(owner, "Owner Authoring Templates")

      secret_payload = %{
        "scope" => %{"project_id" => project.id},
        "starter_draft" => %{"title" => "Owner-only planning draft"},
        "validation_policy" => %{"required_sections" => ["private_context"]}
      }

      insert_template!(name: "owner-project-template", payload: secret_payload)

      assert {:error, :not_found} =
               AuthoringTemplateLookup.get_template(lookup_context(intruder, project), @request)
    end

    test "filters other-project records before callers receive template payloads" do
      user = create_user("authoring-template-project-scope")
      project = create_project(user, "Visible Authoring Templates")
      other_project = create_project(user, "Hidden Authoring Templates")

      visible_payload = %{
        "scope" => %{"project_id" => project.id},
        "starter_draft" => %{"title" => "Visible project draft"},
        "validation_policy" => %{"required_sections" => ["goal"]}
      }

      hidden_payload = %{
        "scope" => %{"project_id" => other_project.id},
        "starter_draft" => %{"title" => "Hidden project draft"},
        "validation_policy" => %{"required_sections" => ["secret"]}
      }

      insert_template!(name: "visible-project-template", payload: visible_payload)
      insert_template!(name: "hidden-project-template", payload: hidden_payload)

      assert {:ok, template} =
               AuthoringTemplateLookup.get_template(lookup_context(user, project), @request)

      assert template.payload == visible_payload
      refute template.payload == hidden_payload
      refute inspect(template.payload) =~ "Hidden project draft"
    end
  end
end
