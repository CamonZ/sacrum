defmodule Sacrum.Accounts.AuthoringTemplateLookupTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{AuthoringTemplateLookup, Projects}
  alias Sacrum.Repo.AuthoringTemplates
  alias Sacrum.Repo.Users

  @request %{
    run_kind: "goal_exploration",
    artifact_type: "workflow_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_goal_exploration"
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

    test "returns a deterministic fallback template when no project-specific record exists" do
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

    test "returns all applicable internal template kinds as structured data" do
      user = create_user("authoring-template-kinds")
      project = create_project(user, "Authoring Template Kinds")

      expected_payloads = %{
        "authoring_rules" => %{"rules" => [%{"id" => "ask-before-assuming"}]},
        "starter_draft" => %{"draft" => %{"title" => "Discovery"}},
        "section_template" => %{"sections" => [%{"kind" => "goal"}]},
        "workflow_recipe" => %{"workflow" => %{"name" => "Backlog"}},
        "prompt_template" => %{"template" => "Use {{ task.title }}"},
        "route_schema" => %{"schema" => %{"type" => "object"}},
        "validation_policy" => %{"required_sections" => ["goal"]}
      }

      for {template_kind, payload} <- expected_payloads do
        insert_template!(
          template_kind: template_kind,
          name: "default-#{template_kind}",
          payload: payload
        )
      end

      assert {:ok, templates} =
               AuthoringTemplateLookup.list_applicable_templates(
                 lookup_context(user, project),
                 Map.take(@request, [:run_kind, :artifact_type, :state_machine_entrypoint])
               )

      assert MapSet.new(Map.keys(templates)) == MapSet.new(Map.keys(expected_payloads))

      for {template_kind, payload} <- expected_payloads do
        assert templates[template_kind] == %{
                 name: "default-#{template_kind}",
                 payload: payload
               }
      end
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
