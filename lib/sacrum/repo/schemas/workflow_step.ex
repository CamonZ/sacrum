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

  @step_types ~w(execute evaluate route wait_children human_input)
  @create_fields ~w(name goal agents skills agent_config is_final step_order step_type prompt output_schema)a
  @update_fields ~w(name goal agents skills agent_config is_final step_order step_type prompt output_schema)a

  @spec step_types() :: [String.t()]
  def step_types, do: @step_types

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
    case validate_routing_contract_schema(schema) do
      :ok ->
        changeset

      {:error, reason} ->
        add_error(
          changeset,
          :output_schema,
          "route steps must use a strict routing contract schema: #{reason}"
        )
    end
  end

  defp validate_routing_contract_schema(changeset, _schema) do
    add_error(changeset, :output_schema, "must be a valid map for route steps")
  end

  @spec routing_contract_schema() :: map()
  def routing_contract_schema do
    routing_contract_schema(nil)
  end

  @spec routing_contract_schema(map() | nil) :: map()
  def routing_contract_schema(nil) do
    %{
      "type" => "object",
      "properties" => %{
        "transition_to" => %{"type" => "string"},
        "transition_type" => %{"type" => "string", "enum" => ["intra_workflow", "inter_workflow"]}
      },
      "required" => ["transition_to", "transition_type"],
      "additionalProperties" => false
    }
  end

  def routing_contract_schema(handoff_schema) when is_map(handoff_schema) do
    schema = routing_contract_schema(nil)

    schema
    |> put_in(["properties", "handoff"], handoff_schema)
    |> put_in(["required"], ["transition_to", "transition_type", "handoff"])
  end

  @spec validate_routing_contract_schema(map()) :: :ok | {:error, String.t()}
  def validate_routing_contract_schema(schema) when is_map(schema) do
    with :ok <- require_exact_value(schema, "type", "object", "top-level type must be object"),
         :ok <-
           require_exact_value(
             schema,
             "additionalProperties",
             false,
             "top-level additionalProperties must be false"
           ),
         {:ok, properties} <- fetch_map(schema, "properties", "properties must be a map"),
         :ok <- validate_route_properties(properties) do
      validate_required_keys(schema, Map.keys(properties), "top-level required")
    end
  end

  def validate_routing_contract_schema(_schema), do: {:error, "schema must be a map"}

  defp validate_route_properties(properties) do
    property_keys = Map.keys(properties)

    cond do
      Enum.sort(property_keys) not in [
        ["transition_to", "transition_type"],
        ["handoff", "transition_to", "transition_type"]
      ] ->
        {:error,
         "properties must contain transition_to, transition_type, and optional handoff only"}

      properties["transition_to"] != %{"type" => "string"} ->
        {:error, "transition_to must be a string schema without format"}

      properties["transition_type"] != %{
        "type" => "string",
        "enum" => ["intra_workflow", "inter_workflow"]
      } ->
        {:error, "transition_type must allow intra_workflow and inter_workflow"}

      handoff_schema = properties["handoff"] ->
        validate_strict_object_schema(handoff_schema, "handoff")

      true ->
        :ok
    end
  end

  defp validate_strict_object_schema(schema, path) when is_map(schema) do
    with :ok <- require_object_type(schema, path),
         :ok <-
           require_exact_value(
             schema,
             "additionalProperties",
             false,
             "#{path}.additionalProperties must be false"
           ),
         {:ok, properties} <- optional_properties(schema, path),
         :ok <- validate_required_keys(schema, Map.keys(properties), "#{path}.required") do
      validate_nested_schemas(properties, path)
    end
  end

  defp validate_strict_object_schema(_schema, path),
    do: {:error, "#{path} must be an object schema"}

  defp validate_nested_schemas(properties, path) do
    Enum.reduce_while(properties, :ok, fn {key, property_schema}, :ok ->
      case validate_nested_schema(property_schema, "#{path}.#{key}") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_nested_schema(schema, path) when is_map(schema) do
    with :ok <- validate_nested_object_schema(schema, path) do
      validate_items_schema(schema, path)
    end
  end

  defp validate_nested_schema(_schema, _path), do: :ok

  defp validate_nested_object_schema(schema, path) do
    if object_schema?(schema) do
      validate_strict_object_schema(schema, path)
    else
      :ok
    end
  end

  defp validate_items_schema(%{"items" => items}, path) when is_map(items) do
    validate_nested_schema(items, "#{path}.items")
  end

  defp validate_items_schema(%{"items" => items}, path) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item_schema, index}, :ok ->
      case validate_nested_schema(item_schema, "#{path}.items[#{index}]") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_items_schema(_schema, _path), do: :ok

  defp object_schema?(schema) do
    type = schema["type"]

    type == "object" or
      (is_list(type) and "object" in type and Enum.all?(type, &(&1 in ["object", "null"])))
  end

  defp require_object_type(schema, path) do
    if object_schema?(schema) do
      :ok
    else
      {:error, "#{path}.type must be object or nullable object"}
    end
  end

  defp optional_properties(schema, path) do
    case Map.get(schema, "properties", %{}) do
      properties when is_map(properties) -> {:ok, properties}
      _ -> {:error, "#{path}.properties must be a map when present"}
    end
  end

  defp validate_required_keys(schema, property_keys, label) do
    required = Map.get(schema, "required")

    cond do
      not is_list(required) ->
        {:error, "#{label} must list every declared property"}

      Enum.sort(required) != Enum.sort(property_keys) ->
        {:error, "#{label} must list every declared property"}

      true ->
        :ok
    end
  end

  defp require_exact_value(schema, key, expected, error_message) do
    if Map.get(schema, key) == expected do
      :ok
    else
      {:error, error_message}
    end
  end

  defp fetch_map(schema, key, error_message) do
    case Map.get(schema, key) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, error_message}
    end
  end
end
