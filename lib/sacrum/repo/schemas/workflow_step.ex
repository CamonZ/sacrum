defmodule Sacrum.Repo.Schemas.WorkflowStep do
  use Ecto.Schema
  import Ecto.Changeset
  require Logger

  alias Sacrum.Orchestrator.Routing.RouteConfig

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
    field :route_config, :map
    field :verbose_daemon_logging, :boolean, default: false

    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :transitions, Sacrum.Repo.Schemas.StepTransition, foreign_key: :from_step_id

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields ~w(name goal agents skills agent_config step_order step_type prompt output_schema route_config)a
  @update_fields ~w(name goal agents skills agent_config step_order step_type prompt output_schema route_config)a

  @spec step_types() :: [atom()]
  def step_types, do: @step_types

  @spec step_type_wire_value(atom() | String.t() | nil) :: String.t() | nil
  def step_type_wire_value(nil), do: nil
  def step_type_wire_value(step_type) when is_atom(step_type), do: Atom.to_string(step_type)
  def step_type_wire_value(step_type), do: step_type

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(step, attrs) do
    step
    |> cast_step(attrs, @create_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_finish_step_prompt()
    |> validate_output_schema()
    |> validate_route_step_schema()
    |> validate_route_config()
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:project_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(step, attrs) do
    step
    |> cast_step(attrs, @update_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_finish_step_prompt()
    |> validate_output_schema()
    |> validate_route_step_schema()
    |> validate_route_config()
  end

  # Private validation functions

  defp cast_step(step, attrs, fields) do
    changeset = cast(step, attrs, fields)

    if submitted_empty_prompt?(attrs), do: put_change(changeset, :prompt, ""), else: changeset
  end

  # Changesets are called directly by atom-keyed repository callers and
  # string-keyed import/API callers. Preserve explicit empty prompts in both
  # formats because Ecto's default cast would otherwise turn them into nil.
  defp submitted_empty_prompt?(%{prompt: prompt}), do: prompt == ""
  defp submitted_empty_prompt?(%{"prompt" => prompt}), do: prompt == ""
  defp submitted_empty_prompt?(_attrs), do: false

  defp validate_finish_step_prompt(changeset) do
    if get_field(changeset, :step_type) == :finish and
         nonblank_prompt?(get_field(changeset, :prompt)) do
      add_error(changeset, :prompt, "must be blank for finish steps")
    else
      changeset
    end
  end

  defp nonblank_prompt?(prompt) when is_binary(prompt), do: String.trim(prompt) != ""
  defp nonblank_prompt?(_prompt), do: false

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
      validate_codex_provider_output_schema(changeset, schema)
    else
      changeset
    end
  end

  defp validate_codex_provider_output_schema(changeset, schema) do
    case validate_codex_strict_schema(schema) do
      :ok ->
        changeset

      {:error, reason} ->
        add_error(changeset, :output_schema, "must be Codex strict-compatible: #{reason}")
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

  defp validate_route_step_schema(changeset) do
    step_type = get_field(changeset, :step_type)
    output_schema = get_field(changeset, :output_schema)
    prompt = get_field(changeset, :prompt)

    case {step_type, prompt, output_schema} do
      {:route, prompt, nil} when not is_nil(prompt) ->
        put_change(changeset, :output_schema, routing_contract_schema())

      {:route, _prompt, schema} when is_map(schema) ->
        validate_routing_contract_schema(changeset, schema)

      _ ->
        changeset
    end
  end

  defp validate_route_config(changeset) do
    case {get_field(changeset, :step_type), get_field(changeset, :route_config)} do
      {_step_type, nil} ->
        changeset

      {:route, route_config} when is_map(route_config) ->
        case RouteConfig.decode(route_config) do
          {:ok, _decoded} ->
            changeset

          {:error, %{path: path, message: message}} ->
            add_error(changeset, :route_config, "#{path}: #{message}")
        end

      {:route, _route_config} ->
        add_error(changeset, :route_config, "must be a map or null")

      {_step_type, _route_config} ->
        add_error(changeset, :route_config, "is only supported for route steps")
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

  @spec validate_codex_strict_schema(map()) :: :ok | {:error, String.t()}
  def validate_codex_strict_schema(schema) when is_map(schema) do
    validate_codex_strict_schema(schema, "schema")
  end

  def validate_codex_strict_schema(_schema), do: {:error, "schema must be a map"}

  defp validate_codex_strict_schema(schema, path) when is_map(schema) do
    cond do
      Map.has_key?(schema, "const") ->
        {:error, "#{path}.const is not supported"}

      is_list(schema["type"]) ->
        {:error, "#{path}.type must be a single string, not a type array"}

      not is_binary(schema["type"]) ->
        {:error, "#{path}.type must be a string"}

      schema["type"] == "object" ->
        validate_codex_strict_object_schema(schema, path)

      schema["type"] == "array" ->
        validate_codex_strict_array_schema(schema, path)

      true ->
        :ok
    end
  end

  defp validate_codex_strict_schema(_schema, path),
    do: {:error, "#{path} must be a schema object"}

  defp validate_codex_strict_object_schema(schema, path) do
    with :ok <-
           require_exact_value(
             schema,
             "additionalProperties",
             false,
             "#{path}.additionalProperties must be false"
           ),
         {:ok, properties} <- fetch_map(schema, "properties", "#{path}.properties must be a map"),
         :ok <- validate_required_keys(schema, Map.keys(properties), "#{path}.required") do
      validate_codex_strict_properties(properties, path)
    end
  end

  defp validate_codex_strict_properties(properties, path) do
    Enum.reduce_while(properties, :ok, fn {key, property_schema}, :ok ->
      case validate_codex_strict_schema(property_schema, "#{path}.#{key}") do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_codex_strict_array_schema(schema, path) do
    case Map.get(schema, "items") do
      items when is_map(items) -> validate_codex_strict_schema(items, "#{path}.items")
      _ -> {:error, "#{path}.items must be a schema object"}
    end
  end

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
