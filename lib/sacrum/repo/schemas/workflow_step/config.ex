defmodule Sacrum.Repo.Schemas.WorkflowStep.Config do
  @moduledoc """
  The closed, versioned `workflow_steps.config` variants.

  `step_type` selects the variant embedded schema; `human_input`, `stop`, and
  `finish` steps carry a null config. This module also holds the validations
  the variants share.
  """

  import Ecto.Changeset

  require Logger

  alias Sacrum.JsonSchema.Strict
  alias __MODULE__.{LlmInference, Route, WaitChildren}

  @version 1

  @types [llm_inference: LlmInference, route: Route, wait_children: WaitChildren]

  @type t :: LlmInference.t() | Route.t() | WaitChildren.t() | nil

  @doc "The variant embedded schemas keyed by `step_type`."
  @spec types() :: keyword(module())
  def types, do: @types

  @doc "The variant schema for `step_type`, or nil for null-config types."
  @spec module(atom()) :: module() | nil
  def module(step_type), do: Keyword.get(@types, step_type)

  @spec validate_version(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_version(changeset) do
    validate_inclusion(changeset, :version, [@version],
      message: "only version #{@version} is supported"
    )
  end

  @doc """
  Checks that `output_schema` is a resolvable JSON Schema and, for Codex-backed
  agents, Codex strict-compatible.
  """
  @spec validate_output_schema(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_output_schema(changeset) do
    case get_field(changeset, :output_schema) do
      nil -> changeset
      schema -> validate_resolvable(changeset, schema)
    end
  end

  defp validate_resolvable(changeset, schema) do
    ExJsonSchema.Schema.resolve(schema)
    validate_provider_output_schema(changeset, schema)
  rescue
    exception ->
      Logger.error(
        "Failed to resolve output_schema: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      add_error(changeset, :output_schema, "must be a valid JSON Schema")
  end

  defp validate_provider_output_schema(changeset, schema) do
    with true <- Map.has_key?(changeset.types, :agent_config),
         true <- codex_strict_provider?(get_field(changeset, :agent_config)),
         {:error, reason} <- Strict.validate(schema) do
      add_error(changeset, :output_schema, "must be Codex strict-compatible: #{reason}")
    else
      _valid -> changeset
    end
  end

  defp codex_strict_provider?(agent_config) when is_map(agent_config) do
    agent_config
    |> Map.get("provider", Map.get(agent_config, :provider))
    |> normalize_provider()
    |> Kernel.in(["openai", "codex"])
  end

  defp codex_strict_provider?(_agent_config), do: false

  defp normalize_provider(provider) when is_atom(provider) and not is_nil(provider),
    do: provider |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(provider) when is_binary(provider),
    do: provider |> String.trim() |> String.downcase()

  defp normalize_provider(_provider), do: nil
end
