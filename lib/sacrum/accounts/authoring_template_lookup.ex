defmodule Sacrum.Accounts.AuthoringTemplateLookup do
  @moduledoc """
  Project-scoped read service for backend authoring template lookup.
  """

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.AuthoringTemplates
  alias Sacrum.Repo.Schemas.{AuthoringTemplate, ChatSession}

  @app_scope_project_id nil
  @work_breakdown_starter_request %{
    run_kind: "work_breakdown",
    artifact_type: "task_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_work_breakdown_authoring"
  }
  @work_breakdown_supporting_template_payload_keys %{
    "section_template" => ~w(required_sections required_section_templates),
    "validation_policy" => ~w(validation_expectations)
  }
  @code_factory_starter_request %{
    run_kind: "code_factory",
    artifact_type: "workflow_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_code_factory_creation"
  }
  @workflow_recipe_template_kind "workflow_recipe"
  @prompt_template_kind "prompt_template"
  @rules_payload_key "rules"

  @type context :: %{required(:user_id) => String.t(), required(:project_id) => String.t()}
  @type request :: %{
          required(:run_kind) => String.t(),
          required(:artifact_type) => String.t(),
          optional(:template_kind) => String.t(),
          required(:state_machine_entrypoint) => String.t()
        }
  @type template_payload :: %{
          run_kind: String.t(),
          artifact_type: String.t(),
          template_kind: String.t(),
          state_machine_entrypoint: String.t(),
          name: String.t(),
          payload: map()
        }

  @spec get_template(context(), request()) :: {:ok, template_payload()} | {:error, term()}
  def get_template(%{user_id: user_id, project_id: project_id}, request)
      when is_binary(user_id) and is_binary(project_id) and is_map(request) do
    with {:ok, _project} <- Projects.get_by(user_id, conditions: [id: project_id]),
         {:ok, template} <- resolve_template(project_id, request) do
      maybe_enrich_template(present_template(template), project_id, request)
    end
  end

  @spec get_template_for_session(ChatSession.t(), request()) ::
          {:ok, template_payload()} | {:error, term()}
  def get_template_for_session(%ChatSession{project_id: project_id}, request)
      when is_map(request) do
    with {:ok, template} <- resolve_template(project_id, request) do
      maybe_enrich_template(present_template(template), project_id, request)
    end
  end

  defp resolve_template(project_id, request) do
    template =
      request
      |> AuthoringTemplates.list_by_classification()
      |> Enum.filter(&scope_matches?(&1, project_id))
      |> Enum.sort_by(&scope_rank(&1, project_id))
      |> List.first()

    case template do
      %AuthoringTemplate{} = template -> {:ok, template}
      nil -> {:error, :not_found}
    end
  end

  defp scope_matches?(%AuthoringTemplate{} = template, project_id) do
    case project_scope(template) do
      ^project_id -> true
      @app_scope_project_id -> true
      _other_project_id -> false
    end
  end

  defp scope_rank(%AuthoringTemplate{} = template, project_id) do
    case project_scope(template) do
      ^project_id -> {0, template.name}
      @app_scope_project_id -> {1, template.name}
    end
  end

  defp project_scope(%AuthoringTemplate{payload: %{"scope" => %{"project_id" => project_id}}}) do
    project_id
  end

  defp project_scope(%AuthoringTemplate{}), do: @app_scope_project_id

  defp present_template(%AuthoringTemplate{} = template) do
    %{
      run_kind: template.run_kind,
      artifact_type: template.artifact_type,
      template_kind: template.template_kind,
      state_machine_entrypoint: template.state_machine_entrypoint,
      name: template.name,
      payload: template.payload
    }
  end

  defp maybe_enrich_template(template, project_id, request) do
    cond do
      requested_template?(request, @work_breakdown_starter_request) ->
        {:ok,
         Map.update!(
           template,
           :payload,
           &Map.merge(&1, supporting_templates_payload(project_id, request))
         )}

      requested_template?(request, @code_factory_starter_request) ->
        enrich_code_factory_template(template, project_id, request)

      true ->
        {:ok, template}
    end
  end

  defp enrich_code_factory_template(template, project_id, request) do
    with {:ok, workflow_payload} <-
           required_supporting_payload(project_id, request, @workflow_recipe_template_kind),
         {:ok, prompt_payload} <-
           required_supporting_payload(project_id, request, @prompt_template_kind),
         {:ok, workflows} <- workflows_from_payload(workflow_payload),
         {:ok, prompts} <- prompts_from_payload(prompt_payload),
         {:ok, workflows} <- attach_step_prompts(workflows, prompts) do
      payload =
        template.payload
        |> merge_supporting_payload(workflow_payload)
        |> merge_supporting_payload(Map.take(prompt_payload, [@rules_payload_key]))
        |> Map.put("workflows", workflows)

      {:ok, %{template | payload: payload}}
    end
  end

  defp supporting_templates_payload(project_id, request) do
    Enum.reduce(@work_breakdown_supporting_template_payload_keys, %{}, fn {template_kind, keys},
                                                                          payload ->
      Map.merge(payload, supporting_template_payload(project_id, request, template_kind, keys))
    end)
  end

  defp supporting_template_payload(project_id, request, template_kind, keys) do
    case resolve_template(project_id, request_with_template_kind(request, template_kind)) do
      {:ok, template} -> Map.take(template.payload, keys)
      {:error, :not_found} -> %{}
    end
  end

  defp required_supporting_payload(project_id, request, template_kind) do
    case resolve_template(project_id, request_with_template_kind(request, template_kind)) do
      {:ok, template} -> {:ok, template.payload}
      {:error, :not_found} -> {:error, {:missing_supporting_template, template_kind}}
    end
  end

  defp workflows_from_payload(%{"workflows" => workflows}) when is_list(workflows),
    do: {:ok, workflows}

  defp workflows_from_payload(_payload),
    do: {:error, {:malformed_supporting_template, @workflow_recipe_template_kind}}

  defp prompts_from_payload(%{"prompts" => prompts}) when is_list(prompts),
    do: {:ok, prompts}

  defp prompts_from_payload(_payload),
    do: {:error, {:malformed_supporting_template, @prompt_template_kind}}

  defp attach_step_prompts(workflows, prompts) do
    prompt_index =
      Map.new(prompts, fn prompt ->
        {{Map.get(prompt, "workflow"), Map.get(prompt, "step")}, prompt}
      end)

    workflows
    |> attach_workflows(prompt_index)
    |> reverse_attached_items()
  end

  defp attach_workflows(workflows, prompt_index) do
    Enum.reduce_while(workflows, {:ok, []}, fn workflow, {:ok, attached} ->
      case attach_workflow_step_prompts(workflow, prompt_index) do
        {:ok, workflow} -> {:cont, {:ok, [workflow | attached]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp attach_workflow_step_prompts(
         %{"key" => workflow_key, "steps" => steps} = workflow,
         prompt_index
       )
       when is_list(steps) do
    case attach_workflow_steps(steps, workflow_key, prompt_index) do
      {:ok, steps} -> {:ok, Map.put(workflow, "steps", Enum.reverse(steps))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attach_workflow_step_prompts(workflow, _prompt_index) when is_map(workflow),
    do: {:ok, workflow}

  defp attach_workflow_step_prompts(_workflow, _prompt_index),
    do: {:error, {:malformed_supporting_template, "workflow_recipe"}}

  defp attach_workflow_steps(steps, workflow_key, prompt_index) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, attached} ->
      case attach_step_prompt(step, workflow_key, prompt_index) do
        {:ok, step} -> {:cont, {:ok, [step | attached]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp attach_step_prompt(%{"key" => step_key} = step, workflow_key, prompt_index) do
    case Map.get(prompt_index, {workflow_key, step_key}) do
      %{"template" => prompt} -> {:ok, Map.put(step, "prompt", prompt)}
      _prompt -> {:ok, step}
    end
  end

  defp attach_step_prompt(_step, _workflow_key, _prompt_index),
    do: {:error, {:malformed_supporting_template, "workflow_recipe"}}

  defp merge_supporting_payload(payload, supporting_payload) do
    Map.merge(payload, supporting_payload, fn
      "scope", starter_scope, _supporting_scope ->
        starter_scope

      "validation_expectations", starter_expectations, supporting_expectations ->
        Enum.uniq(starter_expectations ++ supporting_expectations)

      _key, _starter_value, supporting_value ->
        supporting_value
    end)
  end

  defp request_with_template_kind(request, template_kind) do
    request
    |> Map.drop([:template_kind, "template_kind"])
    |> Map.put(:template_kind, template_kind)
  end

  defp requested_template?(request, expected) do
    Enum.all?(expected, fn {key, value} -> request_value(request, key) == value end)
  end

  defp request_value(request, key),
    do: Map.get(request, key) || Map.get(request, Atom.to_string(key))

  defp reverse_attached_items({:ok, attached}), do: {:ok, Enum.reverse(attached)}
  defp reverse_attached_items({:error, reason}), do: {:error, reason}
end
