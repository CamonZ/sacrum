defmodule Sacrum.Repo.Schemas.WorkflowStep do
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_steps" do
    field :name, :string
    field :goal, :string
    field :agents, {:array, :string}, default: []
    field :skills, {:array, :string}, default: []
    field :agent_config, :map, default: %{}
    field :is_final, :boolean, default: false
    field :step_order, :integer
    field :step_type, :string, default: "execute"
    field :prompt, :string
    field :output_schema, :map
    field :verbose_daemon_logging, :boolean, default: false

    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :transitions, Sacrum.Repo.Schemas.StepTransition, foreign_key: :from_step_id

    timestamps(type: :utc_datetime_usec)
  end

  @step_types ~w(execute evaluate route wait_children)
  @create_fields ~w(name goal agents skills agent_config is_final step_order step_type prompt output_schema)a
  @update_fields ~w(name goal agents skills agent_config is_final step_order step_type prompt output_schema)a

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(step, attrs) do
    step
    |> cast(attrs, @create_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:step_type, @step_types)
    |> validate_output_schema()
    |> validate_route_step_schema()
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:project_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(step, attrs) do
    step
    |> cast(attrs, @update_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:step_type, @step_types)
    |> validate_output_schema()
    |> validate_route_step_schema()
  end

  # Private validation functions

  defp validate_output_schema(changeset) do
    case get_field(changeset, :output_schema) do
      nil ->
        changeset

      schema when is_map(schema) ->
        try do
          ExJsonSchema.Schema.resolve(schema)
          changeset
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

  defp validate_route_step_schema(changeset) do
    step_type = get_field(changeset, :step_type)
    output_schema = get_field(changeset, :output_schema)

    case step_type do
      "route" ->
        if output_schema == nil do
          put_change(changeset, :output_schema, routing_contract_schema())
        else
          validate_routing_contract_schema(changeset, output_schema)
        end

      _ ->
        changeset
    end
  end

  defp validate_routing_contract_schema(changeset, schema) when is_map(schema) do
    # The canonical schema includes handoff, but handoff is optional — so a schema
    # without the handoff property is equally valid.
    if schema == routing_contract_schema() or schema == routing_contract_schema_without_handoff() do
      changeset
    else
      add_error(
        changeset,
        :output_schema,
        "route steps must use the routing contract schema: transition_to (uuid) and transition_type (intra_workflow or inter_workflow)"
      )
    end
  end

  defp validate_routing_contract_schema(changeset, _schema) do
    add_error(changeset, :output_schema, "must be a valid map for route steps")
  end

  @spec routing_contract_schema() :: map()
  def routing_contract_schema do
    %{
      "type" => "object",
      "properties" => %{
        "transition_to" => %{"type" => "string"},
        "transition_type" => %{"type" => "string", "enum" => ["intra_workflow", "inter_workflow"]},
        "handoff" => %{"type" => "object"}
      },
      "required" => ["transition_to", "transition_type"],
      "additionalProperties" => false
    }
  end

  defp routing_contract_schema_without_handoff do
    canonical = routing_contract_schema()
    properties = Map.delete(canonical["properties"], "handoff")
    %{canonical | "properties" => properties}
  end
end
