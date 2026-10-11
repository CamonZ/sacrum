defmodule Sacrum.Routing.SessionDirective do
  @moduledoc """
  How a path into an `llm_inference` step enters a provider conversation:
  `session {mode: new | resume | fork, step_id?}`.

  Route decisions and step transitions carry the same directive. `step_id`
  names the step whose conversation is resumed or forked and defaults to the
  destination; it is not allowed with `new`. The step it names must be an
  `llm_inference` step of the destination's workflow on the destination's
  harness.

  This module owns the shape and those step rules; which destinations a
  carrier may point a directive at is checked by the carrier's validator.
  """

  alias Sacrum.Repo.Schemas.WorkflowStep

  @type t :: %{mode: :new, step_id: nil} | %{mode: :resume | :fork, step_id: String.t() | nil}
  @type error :: %{path: String.t(), message: String.t()}

  @modes %{"new" => :new, "resume" => :resume, "fork" => :fork}

  @doc "Decodes a JSON directive, reporting errors under `path`."
  @spec decode(term(), String.t()) :: {:ok, t()} | {:error, error()}
  def decode(session, path) when is_map(session) do
    with :ok <- validate_keys(session, path),
         {:ok, mode} <- decode_mode(Map.fetch!(session, "mode"), "#{path}.mode") do
      decode_step(mode, Map.fetch(session, "step_id"), "#{path}.step_id")
    end
  end

  def decode(_session, path), do: {:error, error(path, "must be an object")}

  @doc "The persisted JSON form of a decoded directive."
  @spec encode(t()) :: map()
  def encode(%{mode: mode, step_id: nil}), do: %{"mode" => Atom.to_string(mode)}

  def encode(%{mode: mode, step_id: step_id}),
    do: %{"mode" => Atom.to_string(mode), "step_id" => step_id}

  @doc """
  The directive a destination is dispatched with: `%{"mode" => "new"}` or
  `%{"mode" => "resume" | "fork", "step_id" => id}`, with an omitted
  `step_id` resolved to `destination_step_id`.
  """
  @spec entry(t(), String.t()) :: map()
  def entry(%{mode: :new}, _destination_step_id), do: %{"mode" => "new"}

  def entry(%{mode: mode, step_id: step_id}, destination_step_id),
    do: %{"mode" => Atom.to_string(mode), "step_id" => step_id || destination_step_id}

  @doc """
  Checks the step a resume or fork names against the `destination` step.
  `steps` maps step ids to the workflow steps that may be referenced.
  """
  @spec validate_source(t(), WorkflowStep.t(), String.t(), map()) :: :ok | {:error, error()}
  def validate_source(%{step_id: nil}, _destination, _path, _steps), do: :ok

  def validate_source(%{step_id: step_id}, destination, path, steps) do
    case Map.get(steps, step_id) do
      %{step_type: :llm_inference, workflow_id: workflow_id, harness: harness}
      when workflow_id == destination.workflow_id and harness == destination.harness ->
        :ok

      %{step_type: :llm_inference, workflow_id: workflow_id}
      when workflow_id == destination.workflow_id ->
        {:error, error("#{path}.step_id", "must use the same harness as the destination step")}

      _step ->
        {:error, error("#{path}.step_id", "must be an llm_inference step in this workflow")}
    end
  end

  defp validate_keys(session, path) do
    keys = Map.keys(session)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) -> {:error, error(path, "must use string keys")}
      "mode" not in keys -> {:error, error("#{path}.mode", "is required")}
      (unknown = keys -- ["mode", "step_id"]) != [] -> unknown_key(unknown, path)
      true -> :ok
    end
  end

  defp unknown_key([key | _keys], path), do: {:error, error("#{path}.#{key}", "is not allowed")}

  defp decode_mode(mode, path) do
    case Map.fetch(@modes, mode) do
      {:ok, mode} -> {:ok, mode}
      :error -> {:error, error(path, "must be new, resume, or fork")}
    end
  end

  defp decode_step(mode, :error, _path), do: {:ok, %{mode: mode, step_id: nil}}

  defp decode_step(:new, {:ok, _step_id}, path),
    do: {:error, error(path, "is not allowed with mode new")}

  defp decode_step(mode, {:ok, step_id}, path) when is_binary(step_id) do
    case Ecto.UUID.cast(step_id) do
      {:ok, step_id} -> {:ok, %{mode: mode, step_id: step_id}}
      :error -> {:error, error(path, "must be a UUID")}
    end
  end

  defp decode_step(_mode, {:ok, _step_id}, path), do: {:error, error(path, "must be a UUID")}

  defp error(path, message), do: %{path: path, message: message}
end
