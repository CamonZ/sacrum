defmodule Sacrum.Accounts.AuthoringChatLoop do
  @moduledoc """
  Thin tool-triggered authoring state machine for live-chat prototypes.

  Tool intents only drive inspectable authoring draft state. This module does
  not create workflows, tickets, task records, validation results, apply
  records, or GUI command events.
  """

  alias Sacrum.Accounts.{AuthoringDrafts, ChatSessions, LiveChat}
  alias Sacrum.Repo.Schemas.{Artifact, ChatSession}

  @state_machine_id "authoring_chat_loop"
  @feature_exploration "feature_exploration"
  @code_factory_starter_example "code_factory_starter_example"

  @type response :: %{
          assistant_text: String.t(),
          draft: Artifact.t(),
          state: map()
        }

  @spec handle_tool_intent(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def handle_tool_intent(user_id, project_id, chat_session_id, intent, opts \\ [])
      when is_binary(user_id) and is_binary(project_id) and is_binary(chat_session_id) and
             is_map(intent) and is_list(opts) do
    with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
         {:ok, transition} <- transition_for_intent(intent),
         patch <- build_patch(session, transition, opts),
         {:ok, %{artifact: draft}} <-
           AuthoringDrafts.upsert_for_chat_session(session, patch) do
      state = state_from_draft(draft)
      response = %{assistant_text: assistant_text(transition), draft: draft, state: state}

      maybe_persist_assistant(session, response, opts)
    end
  end

  defp transition_for_intent(%{"name" => "authoring.start_feature_exploration"} = intent) do
    arguments = arguments(intent)
    unknowns = list_argument(arguments, "unknowns")

    {:ok,
     %{
       current_state: @feature_exploration,
       entrypoint: @feature_exploration,
       revision: 1,
       knowns: list_argument(arguments, "knowns"),
       unknowns: unknowns,
       open_questions: unknowns,
       assistant_text: feature_exploration_text(unknowns)
     }}
  end

  defp transition_for_intent(%{"name" => "authoring.start_code_factory_example"}) do
    {:ok,
     %{
       current_state: @code_factory_starter_example,
       entrypoint: @code_factory_starter_example,
       revision: 1,
       starter_shape: %{
         "kind" => "code_factory_example",
         "goal" => "Create one task from a user request",
         "inputs" => [%{"name" => "feature_request", "type" => "text"}],
         "outputs" => [%{"kind" => "task_draft", "count" => 1}]
       },
       assistant_text:
         "I started a code-factory starter draft for one task-draft output from one text input."
     }}
  end

  defp transition_for_intent(%{"name" => name} = intent)
       when name in [
              "authoring.continue_feature_exploration",
              "authoring.resume_feature_exploration",
              "authoring.revise_feature_exploration"
            ] do
    response = string_argument(arguments(intent), "response")

    {:ok,
     %{
       current_state: @feature_exploration,
       entrypoint: @feature_exploration,
       revision: :next,
       knowns: present_list(response),
       assistant_text: "I updated the feature exploration draft with: #{response}"
     }}
  end

  defp transition_for_intent(_intent), do: {:error, :unsupported_authoring_intent}

  defp build_patch(%ChatSession{} = session, transition, opts) do
    %{
      state_machine_id: @state_machine_id,
      state_machine_entrypoint: transition.entrypoint,
      current_state: transition.current_state,
      revision: transition.revision,
      source_chat: %{
        chat_session_id: session.id,
        source_message_id: Keyword.get(opts, :source_message_id),
        turn_index: transition.revision
      }
    }
    |> maybe_put(:knowns, Map.get(transition, :knowns))
    |> maybe_put(:unknowns, Map.get(transition, :unknowns))
    |> maybe_put(:open_questions, Map.get(transition, :open_questions))
    |> maybe_put(:starter_shape, Map.get(transition, :starter_shape))
  end

  defp state_from_draft(%Artifact{} = draft) do
    revision = draft.data["revision"]

    %{
      state_machine_id: draft.data["state_machine_id"],
      entrypoint: draft.data["state_machine_entrypoint"],
      current_state: draft.data["current_state"],
      draft_id: draft.id,
      revision: revision,
      revision_identity: %{draft_id: draft.id, revision: revision}
    }
  end

  defp assistant_text(%{assistant_text: assistant_text}), do: assistant_text

  defp maybe_persist_assistant(%ChatSession{} = session, response, opts) do
    if Keyword.get(opts, :persist_assistant, false) do
      persist_assistant(session, response)
    else
      {:ok, response}
    end
  end

  defp persist_assistant(%ChatSession{} = session, response) do
    attrs = %{
      role: :assistant,
      content: response.assistant_text,
      content_format: :plain,
      metadata: %{"authoring_loop" => response.state}
    }

    with {:ok, _message} <-
           LiveChat.send_message(session.user_id, session.project_id, session.id, attrs) do
      {:ok, response}
    end
  end

  defp feature_exploration_text([question | _rest]) do
    "I started a feature exploration draft. #{question}"
  end

  defp feature_exploration_text([]) do
    "I started a feature exploration draft. What outcome should this improve first?"
  end

  defp arguments(%{"arguments" => arguments}) when is_map(arguments), do: arguments
  defp arguments(_intent), do: %{}

  defp list_argument(arguments, key) do
    case Map.get(arguments, key) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      value when is_binary(value) -> [value]
      _value -> []
    end
  end

  defp string_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) -> value
      _value -> ""
    end
  end

  defp present_list(""), do: []
  defp present_list(value), do: [value]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
