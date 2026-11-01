defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.LlmInference do
  @moduledoc """
  Config for `llm_inference` steps, which run a prompt on a daemon.

  How an execution enters a provider conversation is decided by the route
  that led to the step, not by the step (see `Sacrum.Routing.RouteConfig`).

  `agent_config` is forwarded to the daemon verbatim. Its `mcp_config` and
  `strict_mcp_config` are validated by `McpConfig`; other keys are daemon
  settings.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Repo.Schemas.WorkflowStep.Config.McpConfig

  @type t :: %__MODULE__{}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :prompt, :string
    field :output_schema, :map
    field :agents, {:array, :string}, default: []
    field :skills, {:array, :string}, default: []
    field :agent_config, :map, default: %{}
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    # Keep an empty prompt distinct from a missing one.
    config
    |> cast(params, __schema__(:fields), empty_values: [])
    |> Config.validate_version()
    |> Config.validate_output_schema()
    |> validate_mcp_config()
  end

  defp validate_mcp_config(changeset) do
    case McpConfig.validate(get_field(changeset, :agent_config)) do
      :ok ->
        changeset

      {:error, %{path: path, message: message}} ->
        add_error(changeset, :agent_config, "#{path}: #{message}", code: :mcp_config_invalid)
    end
  end
end
