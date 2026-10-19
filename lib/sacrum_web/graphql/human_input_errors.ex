defmodule SacrumWeb.Graphql.HumanInputErrors do
  @moduledoc """
  Translates human_input gate resolution errors into coded GraphQL errors.

  Shared by the artifact attach and the draft operations, so a gate reports
  the same codes however it is resolved.
  """

  @spec translate(term()) :: term()
  def translate({:error, :human_input_execution_not_waiting}) do
    {:error,
     %{
       message: "step execution is not waiting for human input",
       code: "human_input_execution_not_waiting"
     }}
  end

  def translate({:error, :human_input_not_draftable}) do
    {:error,
     %{
       message: "the gate's output_schema does not support drafts",
       code: "human_input_not_draftable"
     }}
  end

  def translate({:error, :human_input_artifact_not_configured}) do
    {:error,
     %{
       message: "the gate does not name an artifact to resolve it with",
       code: "human_input_artifact_not_configured"
     }}
  end

  def translate({:error, :not_human_input_execution}) do
    {:error, %{message: "step execution is not a human_input gate", code: "not_human_input"}}
  end

  def translate({:error, {:unknown_draft_field, fields}}) do
    {:error,
     %{
       message: "not a property of the gate's output_schema: #{Enum.join(fields, ", ")}",
       code: "unknown_draft_field",
       fields: fields
     }}
  end

  def translate({:error, {:draft_incomplete, missing}}) do
    {:error,
     %{
       message: "draft is missing required fields: #{Enum.join(missing, ", ")}",
       code: "draft_incomplete",
       missing: missing
     }}
  end

  def translate({:error, {:invalid_human_input_json, reason}}) do
    {:error,
     %{
       message: "artifact body is not valid JSON: #{Exception.message(reason)}",
       code: "invalid_human_input_json"
     }}
  end

  def translate({:error, {:invalid_human_input, {:validation_failed, violations}}}) do
    {:error,
     Enum.map(violations, fn violation ->
       %{
         message: "response does not satisfy the output_schema: #{violation}",
         code: "invalid_human_input"
       }
     end)}
  end

  def translate({:error, {:invalid_human_input, reason}}) do
    {:error,
     %{
       message: "response does not satisfy the output_schema: #{inspect(reason)}",
       code: "invalid_human_input"
     }}
  end

  def translate(result), do: result
end
