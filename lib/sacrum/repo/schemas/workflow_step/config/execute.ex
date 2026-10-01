defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.Execute do
  @moduledoc """
  Versioned script execution owned by the daemon.
  Authored definitions contain `version`, `script`, and `output_schema`.
  The server strictly renders the Liquid script and records the entire
  canonical PromptContext in the execution-only `context` snapshot.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Routing.HandoffTemplate

  @type t :: %__MODULE__{}
  @max_script_bytes 262_144
  @max_json_bytes 1_048_576
  @max_depth 32
  @max_collection_size 4096
  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :script, :string
    field :context, :map
    field :output_schema, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    config
    |> cast(params, definition_fields())
    |> Config.validate_version()
    |> validate_required([:version, :script, :output_schema])
    |> validate_script_size()
    |> validate_json_bounds(:output_schema)
    |> validate_output_schema()
  end

  @doc "The fields clients may author in workflow definitions."
  @spec definition_fields() :: [atom()]
  def definition_fields, do: [:version, :script, :output_schema]

  @doc false
  @spec max_script_bytes() :: pos_integer()
  def max_script_bytes, do: @max_script_bytes

  @doc "Checks the complete runtime context without interpreting strings as templates."
  @spec validate_context(term()) :: :ok | {:error, map()}
  def validate_context(context) when is_map(context), do: validate_bounds(context, "$.context")
  def validate_context(_context), do: bounds_error("$.context", "must be a JSON object")

  defp validate_script_size(changeset) do
    case get_field(changeset, :script) do
      script when is_binary(script) and byte_size(script) > @max_script_bytes ->
        add_error(changeset, :script, "must be at most #{@max_script_bytes} bytes")

      _ ->
        changeset
    end
  end

  defp validate_json_bounds(changeset, field) do
    case validate_bounds(get_field(changeset, field), "$.#{field}") do
      :ok ->
        changeset

      {:error, %{path: path, message: message}} ->
        add_error(changeset, field, "#{path}: #{message}")
    end
  end

  defp validate_output_schema(changeset) do
    if Keyword.has_key?(changeset.errors, :output_schema),
      do: changeset,
      else: Config.validate_output_schema(changeset)
  end

  defp validate_bounds(value, path) do
    with :ok <- validate_nested_bounds(value, path, 0),
         {:ok, encoded} <- Jason.encode(value) do
      if byte_size(encoded) <= @max_json_bytes,
        do: :ok,
        else: bounds_error(path, "must encode to at most #{@max_json_bytes} bytes")
    else
      {:error, %{path: _} = error} -> {:error, error}
      {:error, _} -> bounds_error(path, "must contain only JSON values")
    end
  end

  defp validate_nested_bounds(_value, path, depth) when depth > @max_depth,
    do: bounds_error(path, "must have nesting depth at most #{@max_depth}")

  defp validate_nested_bounds(value, path, depth) when is_map(value) do
    cond do
      map_size(value) > @max_collection_size ->
        bounds_error(path, "must have at most #{@max_collection_size} entries")

      not Enum.all?(Map.keys(value), &is_binary/1) ->
        bounds_error(path, "must use string keys")

      true ->
        Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
          continue_bounds(
            validate_nested_bounds(nested, HandoffTemplate.path_for_key(path, key), depth + 1)
          )
        end)
    end
  end

  defp validate_nested_bounds(value, path, depth) when is_list(value) do
    if length(value) > @max_collection_size do
      bounds_error(path, "must have at most #{@max_collection_size} entries")
    else
      value
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {nested, index}, :ok ->
        continue_bounds(validate_nested_bounds(nested, "#{path}[#{index}]", depth + 1))
      end)
    end
  end

  defp validate_nested_bounds(value, _path, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: :ok

  defp validate_nested_bounds(_value, path, _depth),
    do: bounds_error(path, "must contain only JSON values")

  defp continue_bounds(:ok), do: {:cont, :ok}
  defp continue_bounds({:error, _} = error), do: {:halt, error}

  defp bounds_error(path, message),
    do: {:error, %{code: :step_config_render_failed, path: path, message: message}}
end
