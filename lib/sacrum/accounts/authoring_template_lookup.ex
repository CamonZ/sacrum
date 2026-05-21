defmodule Sacrum.Accounts.AuthoringTemplateLookup do
  @moduledoc """
  Project-scoped read service for backend authoring template lookup.
  """

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.AuthoringTemplates
  alias Sacrum.Repo.Schemas.AuthoringTemplate

  @app_scope_project_id nil
  @excluded_listing_kinds ~w(entrypoint step_template)

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

  @spec get_template(context(), request()) :: {:ok, template_payload()} | {:error, :not_found}
  def get_template(%{user_id: user_id, project_id: project_id}, request)
      when is_binary(user_id) and is_binary(project_id) and is_map(request) do
    with {:ok, _project} <- Projects.get_by(user_id, conditions: [id: project_id]),
         {:ok, template} <- resolve_template(project_id, request) do
      {:ok, present_template(template)}
    end
  end

  @spec list_applicable_templates(context(), request()) ::
          {:ok, %{String.t() => %{name: String.t(), payload: map()}}} | {:error, :not_found}
  def list_applicable_templates(%{user_id: user_id, project_id: project_id}, request)
      when is_binary(user_id) and is_binary(project_id) and is_map(request) do
    with {:ok, _project} <- Projects.get_by(user_id, conditions: [id: project_id]) do
      {:ok, list_templates_by_kind(project_id, request)}
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

  defp list_templates_by_kind(project_id, request) do
    AuthoringTemplate.template_kinds()
    |> Enum.reject(&(&1 in @excluded_listing_kinds))
    |> Enum.reduce(%{}, &put_template_summary(&1, &2, project_id, request))
  end

  defp put_template_summary(template_kind, templates, project_id, request) do
    case resolve_template(project_id, Map.put(request, :template_kind, template_kind)) do
      {:ok, template} ->
        Map.put(templates, template_kind, present_template_summary(template))

      {:error, :not_found} ->
        templates
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

  defp present_template_summary(%AuthoringTemplate{} = template) do
    %{
      name: template.name,
      payload: template.payload
    }
  end
end
