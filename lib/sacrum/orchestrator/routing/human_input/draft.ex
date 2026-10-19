defmodule Sacrum.Orchestrator.Routing.HumanInput.Draft do
  @moduledoc """
  Field-by-field resolution drafts for waiting `human_input` executions.

  A draft is a durable map of the response being built, stored on the
  execution. `set/3` merge-patches it, validating each value against its
  property's subschema; `submit/2` resolves the gate from a complete draft
  exactly as attaching the configured artifact does. Every operation reports
  a `t:view/0`: which required properties are `missing`, which values are
  `invalid`, and whether the draft is `complete`.

  Only gates whose `output_schema` is draftable (see
  `Sacrum.Repo.Schemas.WorkflowStep.Config.HumanInput.draftable?/1`) accept
  drafts. `set/3` and `submit/2` lock the execution row, so they cannot
  interleave with each other or with an artifact attach.
  """

  import Ecto.Query

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Orchestrator.OutputValidator
  alias Sacrum.Orchestrator.Routing.HumanInput
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.WorkflowStep.Config.HumanInput, as: Config

  @type violation :: %{path: String.t(), message: String.t()}
  @type view :: %{
          execution_id: String.t(),
          values: map(),
          missing: [String.t()],
          invalid: [violation()],
          complete: boolean(),
          updated_at: DateTime.t() | nil
        }

  @doc """
  Reports the draft of a draftable human_input execution.
  """
  @spec get(binary(), binary()) :: {:ok, view()} | {:error, term()}
  def get(user_id, execution_id) when is_binary(user_id) and is_binary(execution_id) do
    with {:ok, execution} <- fetch(user_id, execution_id, false),
         {:ok, _schema} <- draftable_schema(execution) do
      {:ok, view(execution)}
    end
  end

  @doc """
  Merge-patches the draft of a waiting execution with `values`.

  Each key must be a property of the gate's `output_schema` and each value
  must satisfy that property's subschema; `nil` removes the key. All or
  nothing: when any key fails, nothing is stored.
  """
  @spec set(binary(), binary(), map()) :: {:ok, view()} | {:error, term()}
  def set(user_id, execution_id, values)
      when is_binary(user_id) and is_binary(execution_id) and is_map(values) do
    transact(fn ->
      with {:ok, execution} <- fetch_waiting(user_id, execution_id),
           {:ok, schema} <- draftable_schema(execution),
           :ok <- ensure_known_fields(values, schema),
           :ok <- validate_values(values, schema),
           {:ok, updated} <- store(execution, merge(execution.draft, values)) do
        {:ok, view(updated)}
      end
    end)
  end

  @doc """
  Resolves a waiting gate from its complete draft.

  The draft becomes the body of the gate's configured artifact, attached to
  the execution through the same transaction and scheduling path as a
  whole-artifact attach.
  """
  @spec submit(binary(), binary()) :: {:ok, view()} | {:error, term()}
  def submit(user_id, execution_id) when is_binary(user_id) and is_binary(execution_id) do
    result =
      transact(fn ->
        with {:ok, execution} <- fetch_waiting(user_id, execution_id),
             {:ok, _schema} <- draftable_schema(execution),
             {:ok, artifact} <- artifact_name(execution),
             :ok <- ensure_complete(view(execution)),
             {:ok, body} <- Jason.encode(execution.draft),
             {:ok, %{execution: resolved} = resumed} <- attach(user_id, execution, artifact, body) do
          {:ok, {view(resolved), resumed}}
        end
      end)

    with {:ok, {view, resumed}} <- result do
      Artifacts.schedule_resumed_run(resumed)
      {:ok, view}
    end
  end

  @doc """
  The draft a new execution of `config` starts from: the previous attempt's
  `output`, keeping only the keys that still validate.
  """
  @spec seed(Config.t() | term(), String.t() | nil) :: map()
  def seed(%Config{} = config, output) when is_binary(output) do
    with true <- Config.draftable?(config),
         {:ok, %{} = values} <- Jason.decode(output) do
      Map.filter(values, fn {key, value} ->
        Map.has_key?(config.output_schema["properties"], key) and
          validate_property(config.output_schema, key, value) == []
      end)
    else
      _not_seedable -> %{}
    end
  end

  def seed(_config, _output), do: %{}

  @doc """
  Reports the draft held by `execution`.
  """
  @spec view(StepExecution.t()) :: view()
  def view(%StepExecution{config: %Config{output_schema: schema}} = execution) do
    values = execution.draft || %{}

    missing =
      schema
      |> Map.get("required", [])
      |> Enum.reject(&Map.has_key?(values, &1))

    invalid = violations(values, Map.delete(schema, "required"))

    %{
      execution_id: execution.id,
      values: values,
      missing: missing,
      invalid: invalid,
      complete: missing == [] and invalid == [],
      updated_at: execution.draft_updated_at
    }
  end

  defp transact(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp fetch(user_id, execution_id, lock?) do
    query =
      from(e in StepExecution, where: e.user_id == ^user_id and e.id == ^execution_id)

    query = if lock?, do: lock(query, "FOR UPDATE"), else: query

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %StepExecution{step_type: :human_input} = e when lock? -> {:ok, HumanInput.lock_task_run(e)}
      %StepExecution{step_type: :human_input} = e -> {:ok, Repo.preload(e, :task_run)}
      %StepExecution{} -> {:error, :not_human_input_execution}
    end
  end

  defp fetch_waiting(user_id, execution_id) do
    with {:ok, execution} <- fetch(user_id, execution_id, true),
         :ok <- HumanInput.ensure_awaiting_response(execution) do
      {:ok, execution}
    end
  end

  defp draftable_schema(%StepExecution{config: %Config{output_schema: schema} = config}) do
    if Config.draftable?(config), do: {:ok, schema}, else: {:error, :human_input_not_draftable}
  end

  defp draftable_schema(%StepExecution{}), do: {:error, :human_input_not_draftable}

  defp artifact_name(%StepExecution{config: %Config{artifact: artifact}})
       when is_binary(artifact),
       do: {:ok, artifact}

  defp artifact_name(%StepExecution{}), do: {:error, :human_input_artifact_not_configured}

  defp ensure_known_fields(values, %{"properties" => properties}) do
    case values |> Map.keys() |> Enum.reject(&Map.has_key?(properties, &1)) |> Enum.sort() do
      [] -> :ok
      unknown -> {:error, {:unknown_draft_field, unknown}}
    end
  end

  defp validate_values(values, schema) do
    messages =
      values
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, value} -> validate_property(schema, key, value) end)
      |> Enum.map(&"#{&1.path}: #{&1.message}")

    case messages do
      [] -> :ok
      _ -> {:error, {:invalid_human_input, {:validation_failed, messages}}}
    end
  end

  defp validate_property(schema, key, value) do
    property = schema["properties"][key]

    value
    |> violations(property)
    |> Enum.map(&%{&1 | path: "/" <> key <> &1.path})
  end

  defp violations(value, schema) do
    case OutputValidator.validate_output(value, schema) do
      :ok -> []
      {:error, {:validation_failed, messages}} -> Enum.map(messages, &parse_violation/1)
      {:error, reason} -> [%{path: "", message: inspect(reason)}]
    end
  end

  # OutputValidator formats violations as "#<json pointer>: <message>".
  defp parse_violation(formatted) do
    case String.split(formatted, ": ", parts: 2) do
      ["#" <> path, message] -> %{path: path, message: message}
      _other -> %{path: "", message: formatted}
    end
  end

  defp merge(draft, values) do
    Enum.reduce(values, draft || %{}, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp store(execution, draft) do
    execution |> StepExecution.put_draft(draft) |> Repo.update()
  end

  defp ensure_complete(%{missing: [_ | _] = missing}),
    do: {:error, {:draft_incomplete, missing}}

  defp ensure_complete(%{invalid: [_ | _] = invalid}) do
    messages = Enum.map(invalid, &"#{&1.path}: #{&1.message}")
    {:error, {:invalid_human_input, {:validation_failed, messages}}}
  end

  defp ensure_complete(%{complete: true}), do: :ok

  defp attach(user_id, execution, artifact, body) do
    with {:ok, {_result, resumed}} <-
           Artifacts.create_and_link_in_transaction(
             user_id,
             execution.project_id,
             %{filename: artifact <> ".json", body: body},
             %{subject_type: "step_execution", subject_id: execution.id, logical_name: artifact}
           ) do
      {:ok, resumed}
    end
  end
end
