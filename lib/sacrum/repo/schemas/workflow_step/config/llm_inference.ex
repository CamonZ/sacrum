defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.LlmInference do
  @moduledoc """
  Config for `llm_inference` steps, which run a prompt on a daemon.

  `session` optionally names a conversation within the TaskRun:
  `%{"name" => name, "mode" => mode}`, where `mode` is `"new"` (start it),
  `"resume"` (continue it; dispatch fails when the run has none) or
  `"resume_or_new"`. Without `session`, every dispatch is an independent
  conversation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @type t :: %__MODULE__{}

  @session_modes ~w(new resume resume_or_new)
  @max_session_name_bytes 255

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :prompt, :string
    field :output_schema, :map
    field :agents, {:array, :string}, default: []
    field :skills, {:array, :string}, default: []
    field :agent_config, :map, default: %{}
    field :session, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    # Keep an empty prompt distinct from a missing one.
    config
    |> cast(params, __schema__(:fields), empty_values: [])
    |> Config.validate_version()
    |> Config.validate_output_schema()
    |> validate_session()
  end

  @doc "The supported `session.mode` values."
  @spec session_modes() :: [String.t()]
  def session_modes, do: @session_modes

  defp validate_session(changeset) do
    case get_change(changeset, :session) do
      nil ->
        changeset

      session ->
        case normalize_session(session) do
          {:ok, normalized} -> put_change(changeset, :session, normalized)
          {:error, message} -> add_error(changeset, :session, message)
        end
    end
  end

  defp normalize_session(session) do
    session = Map.new(session, fn {key, value} -> {to_string(key), value} end)

    case Map.keys(session) -- ["name", "mode"] do
      [] -> normalize_session_fields(session)
      [key | _] -> {:error, "$.#{key}: is not supported"}
    end
  end

  defp normalize_session_fields(%{"name" => name, "mode" => mode})
       when is_binary(name) and is_binary(mode) do
    cond do
      String.trim(name) == "" ->
        {:error, "$.name: must not be blank"}

      byte_size(name) > @max_session_name_bytes ->
        {:error, "$.name: must be at most #{@max_session_name_bytes} bytes"}

      mode not in @session_modes ->
        {:error, "$.mode: must be one of #{Enum.join(@session_modes, ", ")}"}

      true ->
        {:ok, %{"name" => name, "mode" => mode}}
    end
  end

  defp normalize_session_fields(_session),
    do: {:error, "must have string name and mode"}
end
