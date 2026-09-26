defmodule Sacrum.Repo.Schemas.WorkflowStep do
  use Ecto.Schema
  import Ecto.Changeset
  import PolymorphicEmbed

  alias Sacrum.Orchestrator.PersistenceOptions
  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @step_types [
    :llm_inference,
    :structured_inference,
    :route,
    :wait_children,
    :human_input,
    :stop,
    :finish
  ]

  schema "workflow_steps" do
    field :name, :string
    field :goal, :string
    field :step_order, :integer
    field :step_type, Ecto.Enum, values: @step_types, default: :llm_inference

    polymorphic_embeds_one(:config,
      types: Config.types(),
      use_parent_field_for_type: :step_type,
      on_replace: :update
    )

    field :persistence_options, :map
    field :verbose_daemon_logging, :boolean, default: false

    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :transitions, Sacrum.Repo.Schemas.StepTransition, foreign_key: :from_step_id

    timestamps(type: :utc_datetime_usec)
  end

  @update_fields ~w(name goal step_order persistence_options)a
  @create_fields [:step_type | @update_fields]

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
    |> cast_config(attrs)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_persistence_options()
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:project_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(step, attrs) do
    step
    |> cast(attrs, @update_fields)
    |> validate_step_type_unchanged(attrs)
    |> cast_config(attrs)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_persistence_options()
  end

  # A step struct, or any map carrying a step config.
  @type with_config :: %{required(:config) => Config.t(), optional(atom()) => term()}

  @doc "Reads `key` from the step's config, or nil when the variant has no such field."
  @spec config_value(with_config(), atom()) :: term()
  def config_value(%{config: config}, key), do: config && Map.get(config, key)

  @doc """
  The JSON Schema a step's output must satisfy: the answers schema derived
  from `questions` for `structured_inference` steps, otherwise the variant's
  `output_schema`.
  """
  @spec output_schema(with_config()) :: map() | nil
  def output_schema(%{config: %Config.StructuredInference{questions: questions}}),
    do: Config.StructuredInference.answers_schema(questions)

  def output_schema(step), do: config_value(step, :output_schema)

  defp output_schema_key(:structured_inference), do: :questions
  defp output_schema_key(_step_type), do: :output_schema

  # A step's type is fixed at creation; a different kind of step is a new step.
  defp validate_step_type_unchanged(changeset, attrs) do
    case fetch_attr(attrs, :step_type) do
      {:ok, step_type} -> compare_step_type(changeset, step_type)
      :error -> changeset
    end
  end

  defp compare_step_type(changeset, step_type) do
    case Ecto.Type.cast(__schema__(:type, :step_type), step_type) do
      {:ok, unchanged} when unchanged == changeset.data.step_type ->
        changeset

      {:ok, _changed} ->
        add_error(changeset, :step_type, "cannot be changed; create a new step instead")

      _invalid ->
        add_error(changeset, :step_type, "is invalid")
    end
  end

  # Variant types cast `config` into their embedded schema, with defaults when
  # a new step omits it; null-config types reject any config.
  defp cast_config(changeset, attrs) do
    step_type = get_field(changeset, :step_type)

    case {Config.module(step_type), fetch_attr(attrs, :config)} do
      {nil, {:ok, config}} when not is_nil(config) ->
        add_error(changeset, :config, "must be null for #{step_type} steps")

      {nil, _config} ->
        changeset

      {_module, {:ok, config}} when not is_map(config) ->
        add_error(changeset, :config, "must be an object")

      {module, {:ok, config}} ->
        cast_variant(changeset, module, step_type, config)

      {module, :error} when is_nil(changeset.data.config) ->
        cast_variant(changeset, module, step_type, %{})

      {_module, :error} ->
        changeset
    end
  end

  defp cast_variant(changeset, module, step_type, config) do
    allowed = Enum.map(module.__schema__(:fields), &Atom.to_string/1)

    case config |> Map.keys() |> Enum.map(&to_string/1) |> Enum.reject(&(&1 in allowed)) do
      [] ->
        # An empty map would leave a new step without a config.
        params = if config == %{}, do: %{"version" => 1}, else: config

        changeset = %{changeset | params: Map.put(changeset.params || %{}, "config", params)}
        cast_polymorphic_embed(changeset, :config, required: true)

      unknown ->
        key = unknown |> Enum.sort() |> hd()
        add_error(changeset, :config, "$.#{key}: is not supported for #{step_type} steps")
    end
  end

  defp fetch_attr(attrs, key) do
    with :error <- Map.fetch(attrs, key), do: Map.fetch(attrs, Atom.to_string(key))
  end

  defp validate_persistence_options(changeset) do
    persistence_options = get_field(changeset, :persistence_options)

    case PersistenceOptions.validate(persistence_options) do
      :ok ->
        changeset
        |> validate_persistence_step_type(persistence_options)
        |> validate_persistence_output_schema(persistence_options)

      {:error, reason} ->
        add_error(changeset, :persistence_options, reason)
    end
  end

  defp validate_persistence_step_type(changeset, persistence_options) do
    if not is_nil(PersistenceOptions.artifact_logical_name(persistence_options)) and
         get_field(changeset, :step_type) in [:finish, :stop] do
      add_error(
        changeset,
        :persistence_options,
        "artifact persistence is not supported for #{get_field(changeset, :step_type)} steps"
      )
    else
      changeset
    end
  end

  defp validate_persistence_output_schema(changeset, persistence_options) do
    if not is_nil(PersistenceOptions.artifact_logical_name(persistence_options)) and
         is_nil(config_field(changeset, output_schema_key(get_field(changeset, :step_type)))) do
      add_error(
        changeset,
        :persistence_options,
        "artifact persistence requires output_schema"
      )
    else
      changeset
    end
  end

  defp config_field(changeset, key) do
    case get_field(changeset, :config) do
      %Ecto.Changeset{} = config -> get_field(config, key)
      nil -> nil
      config -> Map.get(config, key)
    end
  end
end
