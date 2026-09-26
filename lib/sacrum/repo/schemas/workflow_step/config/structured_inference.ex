defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.StructuredInference do
  @moduledoc """
  Config for `structured_inference` steps, which send resolved `state` and
  System One `questions` to a provider harness and store the provider's
  answers as the step output.

  `state` is a string, object, or array that may reference task, run, and
  prior-step values with `{{ dotted.path }}` interpolations. `questions` is
  static config in the provider's request vocabulary, keyed by question id:

    * `noul` - `instructions`, optional `criteria` keyed by `"true"`/`"false"`
    * `choice` - `instructions`, `criteria` mapping 1-255 options to a
      description or null
    * `score` - `instructions`, `criteria` listing 2-10 levels

  `answers_schema/1` derives the JSON Schema the provider's answers must
  satisfy from the questions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Repo.Types.JsonContent
  alias Sacrum.Routing.HandoffTemplate

  @type t :: %__MODULE__{}

  @question_types ~w(noul choice score)
  @max_choice_options 255
  @score_levels 2..10

  @probability %{"type" => "number", "minimum" => 0, "maximum" => 1}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :provider, :string
    field :model, :string
    field :state, JsonContent
    field :questions, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    config
    |> cast(params, __schema__(:fields))
    |> Config.validate_version()
    |> validate_required([:provider, :model, :state, :questions])
    |> validate_state()
    |> update_change(:questions, &json_keys/1)
    |> validate_questions()
  end

  # Questions are sent and stored as JSON; string keys match what is read back.
  defp json_keys(questions), do: questions |> Jason.encode!() |> Jason.decode!()

  defp validate_state(changeset) do
    with state when not is_nil(state) <- get_field(changeset, :state),
         {:error, %{path: path, message: message}} <-
           HandoffTemplate.validate_config_template(%{"state" => state}, "$") do
      add_error(changeset, :state, "#{path}: #{message}")
    else
      _valid -> changeset
    end
  end

  defp validate_questions(changeset) do
    case get_field(changeset, :questions) do
      nil ->
        changeset

      questions ->
        questions
        |> question_errors()
        |> Enum.reduce(changeset, fn {path, message}, changeset ->
          add_error(changeset, :questions, "#{path}: #{message}")
        end)
    end
  end

  defp question_errors(questions) when map_size(questions) == 0,
    do: [{"$.questions", "must not be empty"}]

  defp question_errors(questions) do
    questions
    |> Enum.sort()
    |> Enum.flat_map(fn {id, question} ->
      path = "$.questions.#{id}"

      if blank?(id),
        do: [{path, "question id must not be blank"}],
        else: question_errors(path, question)
    end)
  end

  defp question_errors(path, %{"type" => type} = question) when type in @question_types do
    content_errors(path <> ".instructions", Map.get(question, "instructions")) ++
      criteria_errors(path <> ".criteria", type, Map.get(question, "criteria"))
  end

  defp question_errors(path, question) when is_map(question),
    do: [{path <> ".type", "must be one of #{Enum.join(@question_types, ", ")}"}]

  defp question_errors(path, _question), do: [{path, "must be an object"}]

  defp criteria_errors(_path, "noul", nil), do: []

  defp criteria_errors(path, "noul", criteria) when is_map(criteria) do
    Enum.flat_map(Enum.sort(criteria), fn
      {key, value} when key in ["true", "false"] -> content_errors("#{path}.#{key}", value)
      {key, _value} -> [{"#{path}.#{key}", "noul criteria may only contain true and false"}]
    end)
  end

  defp criteria_errors(path, "choice", criteria)
       when is_map(criteria) and map_size(criteria) in 1..@max_choice_options do
    Enum.flat_map(Enum.sort(criteria), fn {option, description} ->
      if blank?(option),
        do: [{"#{path}.#{option}", "option must not be blank"}],
        else: nullable_content_errors("#{path}.#{option}", description)
    end)
  end

  defp criteria_errors(path, "choice", _criteria),
    do: [{path, "must be an object with 1 to #{@max_choice_options} options"}]

  defp criteria_errors(path, "score", criteria)
       when is_list(criteria) and length(criteria) in @score_levels do
    criteria
    |> Enum.with_index()
    |> Enum.flat_map(fn {level, index} -> content_errors("#{path}[#{index}]", level) end)
  end

  defp criteria_errors(path, "score", _criteria),
    do: [{path, "must be an array of #{@score_levels.first} to #{@score_levels.last} levels"}]

  defp criteria_errors(path, _type, _criteria), do: [{path, "must be an object"}]

  defp nullable_content_errors(_path, nil), do: []
  defp nullable_content_errors(path, value), do: content_errors(path, value)

  defp content_errors(path, value) do
    if valid_content?(value),
      do: [],
      else: [{path, "must be a non-blank string, object, or array"}]
  end

  defp valid_content?(value) when is_binary(value), do: not blank?(value)
  defp valid_content?(value), do: is_map(value) or is_list(value)

  defp blank?(value), do: String.trim(value) == ""

  @doc """
  The JSON Schema the provider's answers to `questions` must satisfy: an
  object with exactly one answer per question id. Each answer carries its
  `type` and the typed value; answers may carry additional provider fields.
  """
  @spec answers_schema(map() | nil) :: map() | nil
  def answers_schema(questions) when is_map(questions) and map_size(questions) > 0 do
    %{
      "type" => "object",
      "properties" => Map.new(questions, fn {id, question} -> {id, answer_schema(question)} end),
      "required" => questions |> Map.keys() |> Enum.sort(),
      "additionalProperties" => false
    }
  end

  def answers_schema(_questions), do: nil

  defp answer_schema(%{"type" => "noul"}) do
    answer("noul", %{"noul" => @probability})
  end

  defp answer_schema(%{"type" => "choice", "criteria" => criteria}) when is_map(criteria) do
    options = criteria |> Map.keys() |> Enum.sort()

    answer("choice", %{
      "choice" => %{"type" => "string", "enum" => options},
      "probabilities" => keyed_object(options, @probability),
      "confidence" => @probability
    })
  end

  defp answer_schema(%{"type" => "score", "criteria" => criteria}) when is_list(criteria) do
    max_level = length(criteria) - 1
    levels = Enum.map(0..max_level, &Integer.to_string/1)

    answer("score", %{
      "score" => %{"type" => "number", "minimum" => 0, "maximum" => max_level},
      "legend" => keyed_object(levels, %{"type" => "string"}),
      "probabilities" => keyed_object(levels, @probability),
      "confidence" => @probability
    })
  end

  defp answer_schema(%{"type" => type}), do: answer(type, %{})

  defp answer(type, properties) do
    %{
      "type" => "object",
      "properties" => Map.put(properties, "type", %{"type" => "string", "enum" => [type]}),
      "required" => ["type" | properties |> Map.keys() |> Enum.sort()]
    }
  end

  defp keyed_object(keys, value_schema) do
    %{
      "type" => "object",
      "properties" => Map.new(keys, &{&1, value_schema}),
      "required" => keys,
      "additionalProperties" => false
    }
  end
end
