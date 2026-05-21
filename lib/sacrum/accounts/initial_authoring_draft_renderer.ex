defmodule Sacrum.Accounts.InitialAuthoringDraftRenderer do
  @moduledoc """
  Pure rendering for initial authoring draft payloads.

  This module intentionally does not persist or apply rendered drafts. It only
  packages structured authoring template data with the conversational state
  machine metadata needed by later revision, validation, and apply flows.
  """

  alias Sacrum.Repo.Schemas.AuthoringTemplate

  @template_keys [
    :name | AuthoringTemplate.classification_fields() -- [:state_machine_entrypoint]
  ]

  @payload_keys ~w(
    applies_to
    apply_targets
    apply_target
    artifact_type
    assumptions
    auto_advance
    candidate_work_units
    desired_behavior
    final
    from
    initial_step
    key
    kind
    label
    level
    mode
    name
    number
    open_questions
    output_schema
    prompt
    prompts
    proposed_approach
    reason
    required
    required_sections
    required_section_templates
    requires_output_schema_directive
    rules
    scope
    steps
    target_step
    template_kind
    template
    testing_criteria
    title
    to
    transitions
    transitions_to
    type
    validation_expectations
    workflows
  )a
  @payload_key_lookup Map.new(@payload_keys, &{Atom.to_string(&1), &1})
  @type error_reason :: :not_found | {:missing_option, atom()} | {:missing_template_field, atom()}

  @spec render(map(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def render(template, opts) when is_map(template) and is_list(opts) do
    with {:ok, state_machine_id} <- fetch_opt(opts, :state_machine_id),
         {:ok, initial_state} <- fetch_opt(opts, :initial_state),
         {:ok, entrypoint} <- fetch_template(template, :state_machine_entrypoint),
         {:ok, payload} <- fetch_template(template, :payload) do
      draft = %{
        status: :draft,
        persisted?: false,
        state_machine_id: state_machine_id,
        state_machine_entrypoint: entrypoint,
        initial_state: initial_state,
        revision: normalize_revision(Keyword.get(opts, :revision)),
        template: render_template_metadata(template),
        payload: normalize_payload(payload)
      }

      {:ok, maybe_put_trigger(draft, opts)}
    end
  end

  @spec render_for_tool_entrypoint([map()], keyword()) :: {:ok, map()} | {:error, error_reason()}
  def render_for_tool_entrypoint(templates, opts) when is_list(templates) and is_list(opts) do
    with {:ok, entrypoint} <- fetch_opt(opts, :state_machine_entrypoint),
         {:ok, template} <- find_template_for_entrypoint(templates, entrypoint) do
      render(template, opts)
    end
  end

  defp find_template_for_entrypoint(templates, entrypoint) do
    case Enum.find(templates, &(template_value(&1, :state_machine_entrypoint) == entrypoint)) do
      nil -> {:error, :not_found}
      template -> {:ok, template}
    end
  end

  defp render_template_metadata(template) do
    Map.new(@template_keys, fn key -> {key, template_value(template, key)} end)
  end

  defp normalize_revision(%{number: number} = revision) do
    revision
    |> Map.delete(:number)
    |> Map.delete("number")
    |> Map.put(:source, "authoring_template")
    |> Map.put(:value, number)
  end

  defp normalize_revision(%{"number" => number} = revision) do
    normalized_revision = normalize_payload(revision)

    normalized_revision
    |> Map.delete(:number)
    |> Map.put(:source, "authoring_template")
    |> Map.put(:value, number)
  end

  defp normalize_revision(value) do
    %{source: "authoring_template", value: value}
  end

  defp maybe_put_trigger(draft, opts) do
    case Keyword.fetch(opts, :tool) do
      {:ok, tool} -> Map.put(draft, :trigger, %{tool: tool})
      :error -> draft
    end
  end

  defp fetch_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_template(template, key) do
    case template_value(template, key) do
      nil -> {:error, {:missing_template_field, key}}
      value -> {:ok, value}
    end
  end

  defp template_value(template, key) do
    Map.get(template, key) || Map.get(template, Atom.to_string(key))
  end

  defp normalize_payload(value) when is_list(value), do: Enum.map(value, &normalize_payload/1)

  defp normalize_payload(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      normalized_key = normalize_payload_key(key)

      normalized_value =
        if normalized_key == :output_schema do
          nested_value
        else
          normalize_payload(nested_value)
        end

      {normalized_key, normalized_value}
    end)
  end

  defp normalize_payload(value), do: value

  defp normalize_payload_key(key) when is_atom(key), do: key

  defp normalize_payload_key(key) when is_binary(key) do
    Map.get(@payload_key_lookup, key, key)
  end
end
