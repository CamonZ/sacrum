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
    |> validate_json(:output_schema)
    |> validate_output_schema()
  end

  @doc "The fields clients may author in workflow definitions."
  @spec definition_fields() :: [atom()]
  def definition_fields, do: [:version, :script, :output_schema]

  @doc "Checks the complete runtime context without interpreting strings as templates."
  @spec validate_context(term()) :: :ok | {:error, map()}
  def validate_context(context) when is_map(context), do: validate_value(context, "$.context")
  def validate_context(_context), do: json_error("$.context", "must be a JSON object")

  defp validate_json(changeset, field) do
    case validate_value(get_field(changeset, field), "$.#{field}") do
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

  defp validate_value(value, path) when is_map(value) do
    if Enum.all?(Map.keys(value), &is_binary/1) do
      Enum.reduce_while(value, :ok, fn {key, nested}, :ok ->
        continue_validation(validate_value(nested, HandoffTemplate.path_for_key(path, key)))
      end)
    else
      json_error(path, "must use string keys")
    end
  end

  defp validate_value(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {nested, index}, :ok ->
      continue_validation(validate_value(nested, "#{path}[#{index}]"))
    end)
  end

  defp validate_value(value, _path)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: :ok

  defp validate_value(_value, path), do: json_error(path, "must contain only JSON values")

  defp continue_validation(:ok), do: {:cont, :ok}
  defp continue_validation({:error, _} = error), do: {:halt, error}

  defp json_error(path, message),
    do: {:error, %{code: :step_config_render_failed, path: path, message: message}}
end
