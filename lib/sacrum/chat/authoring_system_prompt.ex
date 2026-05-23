defmodule Sacrum.Chat.AuthoringSystemPrompt do
  @moduledoc """
  Build the static + dynamic system prompt for chat assistants that drive the
  Vertebrae authoring loop.

  The static block lists Vertebrae's four run kinds (feature_exploration,
  work_breakdown, code_factory, investigation_session) and the behavior rules
  the model must follow when deciding whether to call a tool. The dynamic block
  summarizes the currently active authoring draft (state_machine_id,
  current_state, revision, open_questions, last revision_notes) or reports that
  there is no active draft.

  This module deliberately uses the outward-facing product name "Vertebrae" and
  never renders the internal name "Sacrum".
  """

  alias Sacrum.Accounts.AuthoringRunKinds
  alias Sacrum.Repo.Schemas.Artifact

  @type build_opts :: %{
          optional(:active_draft) => Artifact.t() | map() | nil,
          optional(:user_turn_count) => non_neg_integer()
        }

  @doc """
  Build the system prompt string from an optional active draft and conversation
  metadata.

  Options:
    * `:active_draft` — an `%Artifact{}` (or stringified-data map) for the
      session's currently active authoring draft, or `nil` when none exists.
    * `:user_turn_count` — number of user turns accumulated so far (used to
      generate a conversation maturity hint when no active draft exists).
  """
  @spec build(map()) :: String.t()
  def build(opts \\ %{}) when is_map(opts) do
    active_draft = Map.get(opts, :active_draft)
    user_turn_count = Map.get(opts, :user_turn_count, 0)

    Enum.join(
      [
        static_block(),
        "",
        "## Active Draft",
        dynamic_block(active_draft, user_turn_count)
      ],
      "\n"
    )
  end

  defp static_block do
    String.trim_trailing("""
    You are the Vertebrae authoring assistant. You help the user shape work units
    (features, task breakdowns, workflow recipes, investigations) inside Vertebrae
    by holding a conversation and, when you have enough context, calling one of
    two tools: start_authoring or revise_authoring. Vertebrae renders the actual
    artifact server-side once you call a tool — you must not invent UUIDs or
    paste full payloads in your reply.

    ## Run kinds

    #{run_kind_catalog()}

    ## Behavior rules

    1. Keep the conversation grounded. If the user has not described scope,
       desired behavior, or constraints, ask focused clarifying questions before
       calling a tool.
    2. Prefer asking questions over guessing. tool_choice is "auto" — you may
       reply with plain text whenever the conversation needs more context.
    3. Only call start_authoring when no active draft exists for the run kind
       and the user's intent maps cleanly onto one of the four run kinds.
    4. Only call revise_authoring when an active draft already exists for the
       referenced state_machine_id. Carry over the existing state machine
       identifier verbatim.
    5. Pick exactly one run_kind per call. Use the enums in the tool schema.
    6. Trigger heuristics — bias toward start_authoring when the user phrases
       their next step using: "help me design", "lay out the work for",
       "break this into tasks", "investigate why", "create a workflow for",
       "set up a recipe for", "draft tasks for". Bias toward revise_authoring
       when the user references the existing draft ("this", "the current
       plan", "tweak the workflow", "refine the breakdown") AND an active
       draft is present in the Active Draft block below.
    7. Never include a "confidence" field in tool arguments. Sufficiency is
       judged by a separate verifier step, not by you.
    8. Use the user's own wording for candidate_work_units and feedback. Do
       not paraphrase technical terms into generic phrasing.
    """)
  end

  defp run_kind_catalog do
    Enum.map_join(AuthoringRunKinds.all(), "\n", &format_run_kind/1)
  end

  defp format_run_kind(descriptor) do
    "- #{descriptor.run_kind} (artifact_type=#{descriptor.artifact_type}, " <>
      "template_kind=#{descriptor.template_kind}, " <>
      "state_machine_entrypoint=#{descriptor.state_machine_entrypoint}, " <>
      "state_machine_id=#{descriptor.state_machine_id}, " <>
      "initial_state=#{descriptor.initial_state})"
  end

  defp dynamic_block(nil, user_turn_count), do: no_active_draft_block(user_turn_count)
  defp dynamic_block(%{} = active_draft, _user_turn_count), do: active_draft_block(active_draft)

  defp no_active_draft_block(user_turn_count) do
    base = "no active draft"

    case user_turn_count do
      n when is_integer(n) and n >= 3 ->
        "#{base} — User has provided #{n} turns of scope without an active draft. " <>
          "Consider whether you have enough to call start_authoring this turn."

      n when is_integer(n) and n >= 1 ->
        "#{base} — User has provided #{n} turn(s) of scope. Keep gathering context " <>
          "before calling start_authoring."

      _ ->
        base
    end
  end

  defp active_draft_block(%Artifact{data: data}), do: active_draft_block(data || %{})

  defp active_draft_block(%{} = data) do
    String.trim_trailing("""
    state_machine_id: #{string_field(data, "state_machine_id", "(missing)")}
    current_state: #{string_field(data, "current_state", "(missing)")}
    revision: #{revision_display(data)}
    open_questions:
    #{format_list(list_field(data, "open_questions"))}
    last_revision_notes:
    #{format_list(last_note(list_field(data, "revision_notes")))}
    """)
  end

  defp string_field(data, key, default) do
    case Map.get(data, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp revision_display(data) do
    case Map.get(data, "revision") do
      %{"source" => source, "value" => value} -> "#{source}:#{value}"
      %{"value" => value} -> to_string(value)
      value when is_integer(value) -> to_string(value)
      _ -> "(missing)"
    end
  end

  defp list_field(data, key) do
    case Map.get(data, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp format_list([]), do: "  (none)"

  defp format_list(items) do
    Enum.map_join(items, "\n", &"  - #{to_string(&1)}")
  end

  defp last_note([]), do: []
  defp last_note(list) when is_list(list), do: [List.last(list)]
end
