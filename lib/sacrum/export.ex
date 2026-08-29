defmodule Sacrum.Export do
  @moduledoc """
  Encodes the supported versioned project-data JSON boundary.

  Project data is a transport document, not a database dump. The exporter keeps
  route programs and execution audit documents as inert JSON values so callers
  can persist or transmit them without deriving one from another.
  """

  alias Sacrum.Repo.Schemas.WorkflowStep

  @version 1

  @workflow_step_fields ~w(
    id name goal agents skills agent_config step_order step_type prompt output_schema
    persistence_options route_config verbose_daemon_logging workflow_id project_id inserted_at
    updated_at
  )a

  @step_execution_fields ~w(
    id task_id task_run_id workflow_id step_id project_id step_name step_type status context prompt
    output transition_result model model_provider input_tokens output_tokens cost duration_ms handoff
    session_input_tokens session_cache_read_input_tokens session_output_tokens session_total_tokens
    context_window_input_tokens context_window_cache_read_input_tokens context_window_total_tokens
    inserted_at updated_at
  )a

  @doc "Returns a JSON-ready workflow-step record with route_config unchanged."
  @spec workflow_step(map()) :: map()
  def workflow_step(step) when is_map(step) do
    @workflow_step_fields
    |> Enum.reduce(%{}, fn field, output ->
      Map.put(output, Atom.to_string(field), export_value(field, field_value(step, field)))
    end)
    |> Map.put("step_type", WorkflowStep.step_type_wire_value(field_value(step, :step_type)))
  end

  @doc "Returns a JSON-ready StepExecution record with its audit fields unchanged."
  @spec step_execution(map()) :: map()
  def step_execution(execution) when is_map(execution) do
    @step_execution_fields
    |> Enum.reduce(%{}, fn field, output ->
      Map.put(output, Atom.to_string(field), export_value(field, field_value(execution, field)))
    end)
    |> Map.put("step_type", WorkflowStep.step_type_wire_value(field_value(execution, :step_type)))
  end

  @doc "Builds the versioned project-data document from row records."
  @spec project_data(map()) :: map()
  def project_data(data) when is_map(data) do
    document = %{
      "version" => @version,
      "workflow_steps" =>
        data
        |> field_value(:workflow_steps)
        |> List.wrap()
        |> Enum.map(&workflow_step/1),
      "step_executions" =>
        data
        |> field_value(:step_executions)
        |> List.wrap()
        |> Enum.map(&step_execution/1)
    }

    case field_value(data, :project) do
      nil -> document
      project -> Map.put(document, "project", project)
    end
  end

  @doc "Encodes a versioned project-data document as JSON."
  @spec encode(map()) :: {:ok, String.t()} | {:error, Jason.EncodeError.t()}
  def encode(data) when is_map(data) do
    data
    |> project_data()
    |> Jason.encode()
  end

  defp field_value(map, field), do: Map.get(map, field, Map.get(map, Atom.to_string(field)))

  defp export_value(_field, %DateTime{} = value), do: DateTime.to_iso8601(value)
  defp export_value(:cost, %Decimal{} = value), do: Decimal.to_string(value)
  defp export_value(_field, value), do: value
end
