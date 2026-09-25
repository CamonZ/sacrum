defmodule Sacrum.Orchestrator.StructuredInference do
  @moduledoc """
  Result contract for `structured_inference` executions.

  A provider harness completes the execution with an output string encoding
  `{"output": value, "meta": meta}`. `output` must satisfy the `fields` JSON
  Schema in the execution's rendered config; the optional `meta` holds
  per-property provider signals (`probabilities`, `confidence`) under a fixed
  Sacrum-owned schema. Only the validated `output` value is stored in
  `StepExecution.output`; `meta` is stored under
  `StepExecution.context["structured_inference"]`, which harness updates cannot
  replace. A result that fails either check fails the execution instead of
  being stored as successful output.
  """

  alias Sacrum.Orchestrator.OutputValidator
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @context_key "structured_inference"

  @probability %{"type" => "number", "minimum" => 0, "maximum" => 1}

  @property_meta_schema %{
    "type" => "object",
    "properties" => %{
      "probabilities" => %{"type" => "object", "additionalProperties" => @probability},
      "confidence" => @probability
    },
    "additionalProperties" => false
  }

  @doc "The provider `meta` stored with a completed execution, if any."
  @spec meta(map() | nil) :: map() | nil
  def meta(%{@context_key => %{"meta" => meta}}) when is_map(meta), do: meta
  def meta(_context), do: nil

  @doc """
  The schema `meta` must satisfy: an object keyed by the `fields` properties,
  each holding optional `probabilities` and `confidence`.
  """
  @spec meta_schema(map()) :: map()
  def meta_schema(%{"properties" => properties}) when is_map(properties) do
    %{
      "type" => "object",
      "properties" =>
        Map.new(properties, fn {name, _schema} -> {name, @property_meta_schema} end),
      "additionalProperties" => false
    }
  end

  def meta_schema(_fields),
    do: %{"type" => "object", "additionalProperties" => @property_meta_schema}

  @doc """
  Prepares a `StepExecution` update. For structured_inference executions the
  stored `meta` is server-owned and cannot be replaced, and an update that
  completes the execution, or changes a completed execution's output, carries
  a harness result that is validated before it is stored. Other executions are
  returned unchanged.
  """
  @spec prepare_update(StepExecution.t(), map()) :: map()
  def prepare_update(%StepExecution{step_type: :structured_inference} = execution, attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> keep_server_context(execution.context)

    if completes?(execution, attrs) do
      context = Map.get(attrs, "context", execution.context)
      raw_output = Map.get(attrs, "output", execution.output)
      Map.merge(attrs, complete(execution.config, context, raw_output))
    else
      attrs
    end
  end

  def prepare_update(_execution, attrs), do: attrs

  defp keep_server_context(%{"context" => context} = attrs, existing) when is_map(context) do
    context =
      context
      |> Map.delete(@context_key)
      |> Map.merge(Map.take(existing || %{}, [@context_key]))

    Map.put(attrs, "context", context)
  end

  defp keep_server_context(attrs, _existing), do: attrs

  defp completes?(execution, attrs) do
    Map.get(attrs, "status", execution.status) == "completed" and
      (Map.has_key?(attrs, "output") or execution.status != "completed")
  end

  @doc """
  Validates a harness result against the execution's rendered config and
  returns the attrs to store: the encoded `output` value plus `context` with
  `meta` recorded. An invalid result returns a failed-status update carrying
  the rejection reason.
  """
  @spec complete(Config.t(), map() | nil, term()) :: map()
  def complete(config, context, raw_output) do
    with {:ok, fields} <- fetch_fields(config),
         {:ok, output, meta} <- decode_result(raw_output),
         :ok <- validate(output, fields, "output"),
         :ok <- validate(meta, meta_schema(fields), "meta"),
         {:ok, encoded} <- Jason.encode(output) do
      %{"output" => encoded, "context" => put_meta(context || %{}, meta)}
    else
      {:error, reason} ->
        %{"status" => "failed", "output" => "structured output rejected: #{reason}"}
    end
  end

  defp fetch_fields(%Config.StructuredInference{fields: fields}) when is_map(fields),
    do: {:ok, fields}

  defp fetch_fields(_config), do: {:error, "execution config is missing"}

  defp decode_result(raw_output) when is_binary(raw_output) do
    case Jason.decode(raw_output) do
      {:ok, %{"output" => output} = result} -> {:ok, output, Map.get(result, "meta")}
      {:ok, _other} -> {:error, "result must be an object with an output key"}
      {:error, _reason} -> {:error, "result must be valid JSON"}
    end
  end

  defp decode_result(_raw_output), do: {:error, "result is missing"}

  defp validate(nil, _schema, "meta"), do: :ok

  defp validate(value, schema, label) do
    case OutputValidator.validate_output(value, schema) do
      :ok -> :ok
      {:error, {:validation_failed, errors}} -> {:error, "#{label} #{Enum.join(errors, "; ")}"}
      {:error, reason} -> {:error, "#{label} #{inspect(reason)}"}
    end
  end

  defp put_meta(context, nil), do: context
  defp put_meta(context, meta), do: Map.put(context, @context_key, %{"meta" => meta})
end
