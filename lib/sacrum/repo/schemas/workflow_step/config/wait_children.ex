defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.WaitChildren do
  @moduledoc """
  Config for `wait_children` steps. `output_schema` validates the child-state
  snapshot when the step persists it as an artifact.

  `session` lets every child run this step creates fork a conversation of the
  parent run: `{mode: "fork", step_id}`, where `step_id` names an
  `llm_inference` step of the parent's workflow (checked by the graph
  validator). Children may only fork, never resume, so no two runs take turns
  in one provider session.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Routing.SessionDirective

  @type t :: %__MODULE__{}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :output_schema, :map
    field :session, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    config
    |> cast(params, __schema__(:fields))
    |> Config.validate_version()
    |> Config.validate_output_schema()
    |> validate_session()
  end

  defp validate_session(changeset) do
    case get_change(changeset, :session) do
      nil ->
        changeset

      session ->
        case decode_session(session) do
          {:ok, directive} ->
            put_change(changeset, :session, SessionDirective.encode(directive))

          {:error, %{path: path, message: message}} ->
            add_error(changeset, :session, "#{path}: #{message}")
        end
    end
  end

  @doc "Decodes a `wait_children` session: a fork naming its source step."
  @spec decode_session(term()) :: {:ok, SessionDirective.t()} | {:error, SessionDirective.error()}
  def decode_session(session) do
    case SessionDirective.decode(session, "$.session") do
      {:ok, %{mode: :fork, step_id: step_id} = directive} when is_binary(step_id) ->
        {:ok, directive}

      {:ok, %{mode: :fork}} ->
        {:error, %{path: "$.session.step_id", message: "is required"}}

      {:ok, _directive} ->
        {:error, %{path: "$.session.mode", message: "must be fork"}}

      {:error, _reason} = error ->
        error
    end
  end
end
