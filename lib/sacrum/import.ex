defmodule Sacrum.Import do
  @moduledoc """
  Decodes the supported versioned project-data JSON boundary.

  Import only maps persisted JSON to changeset attributes. It does not migrate
  legacy rows, infer route rules from prompts, or reconstruct route audit data
  from ordinary step output. Callers that persist the mapped attributes should
  use the normal WorkflowStep and StepExecution changesets/repositories.
  """

  alias Ecto.Changeset

  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

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

  @doc """
  Loads a versioned project-data JSON string or decoded document.

  The returned records are atom-keyed changeset attributes. JSON values in
  `route_config`, `context`, `transition_result`, and `handoff` are not edited.
  """
  @spec load(String.t() | map()) :: {:ok, map()} | {:error, term()}
  def load(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, document} -> load(document)
      {:error, reason} -> {:error, {:json_decode, reason}}
    end
  end

  def load(%{"version" => @version} = document) do
    with {:ok, workflow_steps} <- load_records(document, "workflow_steps", &load_workflow_step/1),
         {:ok, step_executions} <-
           load_records(document, "step_executions", &load_step_execution/1) do
      {:ok,
       %{
         version: @version,
         project: Map.get(document, "project"),
         workflow_steps: workflow_steps,
         step_executions: step_executions
       }}
    end
  end

  def load(%{"version" => version}), do: {:error, {:unsupported_version, version}}
  def load(_document), do: {:error, :invalid_project_data}

  @doc "Maps one persisted workflow-step record to changeset attributes."
  @spec workflow_step_attrs(map()) :: map()
  def workflow_step_attrs(record) when is_map(record),
    do: copy_present_fields(record, @workflow_step_fields)

  @doc "Maps one persisted StepExecution record to changeset attributes."
  @spec step_execution_attrs(map()) :: map()
  def step_execution_attrs(record) when is_map(record),
    do: copy_present_fields(record, @step_execution_fields)

  @doc "Builds the normal WorkflowStep changeset used by an importing caller."
  @spec workflow_step_changeset(WorkflowStep.t(), map()) :: Changeset.t()
  def workflow_step_changeset(%WorkflowStep{} = step, record) when is_map(record) do
    attrs = workflow_step_attrs(record)

    attrs
    |> then(&WorkflowStep.create_changeset(step, &1))
    |> reject_non_runnable_route(attrs)
  end

  @doc "Builds the normal StepExecution changeset used by an importing caller."
  @spec step_execution_changeset(StepExecution.t(), map()) :: Changeset.t()
  def step_execution_changeset(%StepExecution{} = execution, record) when is_map(record) do
    StepExecution.create_changeset(execution, step_execution_attrs(record))
  end

  defp load_records(document, key, loader) do
    case Map.get(document, key, []) do
      records when is_list(records) ->
        records
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, &load_record(&1, &2, key, loader))
        |> reverse_loaded_records()

      _other ->
        {:error, {key, :must_be_an_array}}
    end
  end

  defp reverse_loaded_records({:ok, records}), do: {:ok, Enum.reverse(records)}
  defp reverse_loaded_records(error), do: error

  defp load_record({record, index}, {:ok, loaded}, key, loader) do
    case loader.(record) do
      {:ok, value} -> {:cont, {:ok, [value | loaded]}}
      {:error, reason} -> {:halt, {:error, {key, index, reason}}}
    end
  end

  defp load_workflow_step(record) when is_map(record) do
    attrs = workflow_step_attrs(record)
    changeset = workflow_step_changeset(%WorkflowStep{}, record)

    if changeset.valid? do
      {:ok, attrs}
    else
      {:error, changeset}
    end
  end

  defp load_workflow_step(_record), do: {:error, :must_be_an_object}

  defp load_step_execution(record) when is_map(record) do
    attrs = step_execution_attrs(record)
    changeset = step_execution_changeset(%StepExecution{}, record)

    if changeset.valid? do
      {:ok, attrs}
    else
      {:error, changeset}
    end
  end

  defp load_step_execution(_record), do: {:error, :must_be_an_object}

  defp copy_present_fields(record, fields) do
    Enum.reduce(fields, %{}, fn field, attrs ->
      case fetch_present_field(record, field) do
        {:ok, value} -> Map.put(attrs, field, value)
        :error -> attrs
      end
    end)
  end

  defp fetch_present_field(record, field) do
    case Map.fetch(record, Atom.to_string(field)) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(record, field)
    end
  end

  defp reject_non_runnable_route(changeset, attrs) do
    if Map.get(attrs, :step_type) in [:route, "route"] and
         is_nil(Map.get(attrs, :route_config)) and is_nil(Map.get(attrs, :prompt)) do
      Changeset.add_error(
        changeset,
        :prompt,
        "route steps require route_config or a non-null prompt"
      )
    else
      changeset
    end
  end
end
