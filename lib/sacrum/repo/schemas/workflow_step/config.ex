defmodule Sacrum.Repo.Schemas.WorkflowStep.Config do
  @moduledoc """
  The closed, versioned `workflow_steps.config` variants.

  `step_type` selects the variant embedded schema; `human_input`, `stop`, and
  `finish` steps carry a null config. This module also holds the validations
  the variants share.
  """

  import Ecto.Changeset

  require Logger

  alias __MODULE__.{LlmInference, Route, StructuredInference, WaitChildren}

  @version 1

  @types [
    llm_inference: LlmInference,
    structured_inference: StructuredInference,
    route: Route,
    wait_children: WaitChildren
  ]

  @type t ::
          LlmInference.t() | StructuredInference.t() | Route.t() | WaitChildren.t() | nil

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
  Checks that the output schema in `field` is a resolvable JSON Schema.
  """
  @spec validate_output_schema(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_output_schema(changeset, field \\ :output_schema) do
    case get_field(changeset, field) do
      nil -> changeset
      schema -> validate_resolvable(changeset, field, schema)
    end
  end

  defp validate_resolvable(changeset, field, schema) do
    ExJsonSchema.Schema.resolve(schema)
    changeset
  rescue
    exception ->
      Logger.error(
        "Failed to resolve output_schema: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      add_error(changeset, field, "must be a valid JSON Schema")
  end
end
