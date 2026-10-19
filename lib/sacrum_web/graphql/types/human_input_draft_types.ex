defmodule SacrumWeb.Graphql.Types.HumanInputDraftTypes do
  @moduledoc """
  GraphQL types and operations for field-by-field human_input resolution
  drafts.
  """

  use Absinthe.Schema.Notation

  alias Sacrum.Orchestrator.Routing.HumanInput.Draft
  alias SacrumWeb.Graphql.HumanInputErrors

  object :human_input_draft_violation do
    field :path, non_null(:string) do
      description("JSON pointer to the offending value, e.g. /approved; empty for the draft.")
    end

    field :message, non_null(:string)
  end

  object :human_input_draft do
    field :execution_id, non_null(:id)
    field :values, non_null(:json)

    field :missing, non_null(list_of(non_null(:string))) do
      description("Required properties not yet set.")
    end

    field :invalid, non_null(list_of(non_null(:human_input_draft_violation))) do
      description("Values that violate the schema, excluding missing required properties.")
    end

    field :complete, non_null(:boolean) do
      description("True when nothing required is missing and the whole draft validates.")
    end

    field :updated_at, :datetime
  end

  object :human_input_draft_queries do
    field :human_input_draft, :human_input_draft do
      arg(:execution_id, non_null(:uuid4))

      resolve(fn %{execution_id: execution_id}, %{context: %{current_user: user}} ->
        user.id |> Draft.get(execution_id) |> HumanInputErrors.translate()
      end)
    end
  end

  object :human_input_draft_mutations do
    field :set_human_input_draft, :human_input_draft do
      description("Merge-patches the draft; a null value removes its key. All or nothing.")
      arg(:execution_id, non_null(:uuid4))
      arg(:values, non_null(:json))

      resolve(fn %{execution_id: execution_id, values: values},
                 %{context: %{current_user: user}} ->
        if is_map(values) do
          user.id |> Draft.set(execution_id, values) |> HumanInputErrors.translate()
        else
          {:error, %{message: "values must be a JSON object", code: "invalid_human_input"}}
        end
      end)
    end

    field :submit_human_input_draft, :human_input_draft do
      description("Resolves the gate from the complete draft, like attaching its artifact.")
      arg(:execution_id, non_null(:uuid4))

      resolve(fn %{execution_id: execution_id}, %{context: %{current_user: user}} ->
        user.id |> Draft.submit(execution_id) |> HumanInputErrors.translate()
      end)
    end
  end
end
