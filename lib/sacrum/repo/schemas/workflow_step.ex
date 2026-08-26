defmodule Sacrum.Repo.Schemas.WorkflowStep do
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  alias Sacrum.JsonSchema.Strict
  alias Sacrum.Orchestrator.PersistenceOptions
  alias Sacrum.Routing.{Contract, RouteConfig}

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @step_types [:execute, :evaluate, :route, :wait_children, :human_input, :stop, :finish]

  schema "workflow_steps" do
    field :name, :string
    field :goal, :string
    field :agents, {:array, :string}, default: []
    field :skills, {:array, :string}, default: []
    field :agent_config, :map, default: %{}
    field :step_order, :integer
    field :step_type, Ecto.Enum, values: @step_types, default: :execute
    field :prompt, :string
    field :output_schema, :map
    field :persistence_options, :map
    field :route_config, :map
    field :verbose_daemon_logging, :boolean, default: false

    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :transitions, Sacrum.Repo.Schemas.StepTransition, foreign_key: :from_step_id

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields ~w(name goal agents skills agent_config step_order step_type prompt output_schema persistence_options route_config)a
  @update_fields ~w(name goal agents skills agent_config step_order step_type prompt output_schema persistence_options route_config)a

  @spec step_types() :: [atom()]
  def step_types, do: @step_types

  @spec step_type_wire_value(atom() | String.t() | nil) :: String.t() | nil
  def step_type_wire_value(nil), do: nil
  def step_type_wire_value(step_type) when is_atom(step_type), do: Atom.to_string(step_type)
  def step_type_wire_value(step_type), do: step_type

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(step, attrs) do
    step
    |> cast(attrs, @create_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_finish_step_prompt()
    |> validate_output_schema()
    |> validate_route_step()
    |> validate_persistence_options()
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:project_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(step, attrs) do
    step
    |> cast(attrs, @update_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_finish_step_prompt()
    |> validate_output_schema()
    |> validate_route_step()
    |> validate_persistence_options()
  end

  defp validate_persistence_options(changeset) do
    persistence_options = get_field(changeset, :persistence_options)

    case PersistenceOptions.validate(persistence_options) do
      :ok ->
        validate_persistence_output_schema(changeset, persistence_options)

      {:error, reason} ->
        add_error(changeset, :persistence_options, reason)
    end
  end

  defp validate_persistence_output_schema(changeset, persistence_options) do
    if PersistenceOptions.artifact_configured?(persistence_options) and
         is_nil(get_field(changeset, :output_schema)) do
      add_error(
        changeset,
        :persistence_options,
        "artifact persistence requires output_schema"
      )
    else
      changeset
    end
  end

  defp validate_finish_step_prompt(changeset) do
    if get_field(changeset, :step_type) == :finish and
         not is_nil(get_field(changeset, :prompt)) do
      add_error(changeset, :prompt, "must be blank for finish steps")
    else
      changeset
    end
  end

  defp validate_output_schema(changeset) do
    case get_field(changeset, :output_schema) do
      nil ->
        changeset

      schema when is_map(schema) ->
        try do
          ExJsonSchema.Schema.resolve(schema)
          validate_provider_output_schema(changeset, schema)
        rescue
          exception ->
            Logger.error(
              "Failed to resolve output_schema: #{Exception.format(:error, exception, __STACKTRACE__)}"
            )

            add_error(changeset, :output_schema, "must be a valid JSON Schema")
        end

      _ ->
        add_error(changeset, :output_schema, "must be a map or null")
    end
  end

  defp validate_provider_output_schema(changeset, schema) do
    if codex_strict_provider?(get_field(changeset, :agent_config)) do
      case Strict.validate(schema) do
        :ok ->
          changeset

        {:error, reason} ->
          add_error(changeset, :output_schema, "must be Codex strict-compatible: #{reason}")
      end
    else
      changeset
    end
  end

  defp codex_strict_provider?(agent_config) when is_map(agent_config) do
    provider =
      agent_config
      |> Map.get("provider", Map.get(agent_config, :provider))
      |> normalize_provider()

    provider in ["openai", "codex"]
  end

  defp codex_strict_provider?(_agent_config), do: false

  defp normalize_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> normalize_provider()
  end

  defp normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_provider(_provider), do: nil

  defp validate_route_step(changeset) do
    changeset
    |> validate_route_config_scope()
    |> validate_route_config()
    |> validate_route_output_schema()
  end

  defp validate_route_config_scope(changeset) do
    case {get_field(changeset, :step_type), get_field(changeset, :route_config)} do
      {_step_type, nil} ->
        changeset

      {:route, _route_config} ->
        changeset

      {_step_type, _route_config} ->
        add_error(changeset, :route_config, "is only supported for route steps")
    end
  end

  defp validate_route_config(%{valid?: false} = changeset), do: changeset

  defp validate_route_config(changeset) do
    case {get_field(changeset, :step_type), get_field(changeset, :route_config)} do
      {:route, route_config} when is_map(route_config) ->
        case RouteConfig.decode(route_config) do
          {:ok, _program} ->
            changeset

          {:error, %{path: path, message: message}} ->
            add_error(changeset, :route_config, "#{path}: #{message}")
        end

      _ ->
        changeset
    end
  end

  defp validate_route_output_schema(changeset) do
    case {get_field(changeset, :step_type), get_field(changeset, :output_schema),
          get_field(changeset, :route_config)} do
      {:route, nil, nil} ->
        if is_nil(get_field(changeset, :prompt)) do
          changeset
        else
          put_change(changeset, :output_schema, Contract.output_schema())
        end

      {:route, nil, _route_config} ->
        changeset

      {:route, schema, _route_config} when is_map(schema) ->
        case Contract.validate_output_schema(schema) do
          :ok ->
            changeset

          {:error, reason} ->
            add_error(
              changeset,
              :output_schema,
              "route steps must use a strict routing contract schema: #{reason}"
            )
        end

      _ ->
        changeset
    end
  end
end
