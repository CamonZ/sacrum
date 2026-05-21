defmodule Sacrum.Accounts.AuthoringChatLoop do
  @moduledoc """
  Thin tool-triggered authoring state machine for live-chat prototypes.

  Tool intents only drive inspectable authoring draft state. This module does
  not create workflows, tickets, task records, validation results, apply
  records, or GUI command events.
  """

  alias Sacrum.Accounts.{
    AuthoringDrafts,
    AuthoringTemplateLookup,
    ChatSessions,
    InitialAuthoringDraftRenderer,
    LiveChat
  }

  alias Sacrum.Chat.Inference
  alias Sacrum.Repo.Schemas.{Artifact, AuthoringTemplate, ChatSession}

  @state_machine_id "authoring_chat_loop"
  @feature_exploration "feature_exploration"

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

  @spec apply_inference_result(ChatSession.t(), Inference.Result.t()) :: :ok | {:error, term()}
  def apply_inference_result(%ChatSession{} = session, %Inference.Result{} = inference_result) do
    apply_inference_metadata(session, inference_result.internal_metadata || %{})
  end

  @spec apply_inference_metadata(ChatSession.t(), map()) :: :ok | {:error, term()}
  def apply_inference_metadata(%ChatSession{} = session, metadata) when is_map(metadata) do
    case get_in(metadata, ["authoring_tool_intent"]) do
      nil -> :ok
      %{} = intent -> apply_authoring_intent(session, intent)
      _intent -> {:error, :invalid_authoring_tool_intent}
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

  defp apply_authoring_intent(%ChatSession{} = session, %{"action" => "start_authoring"} = intent) do
    request = Map.take(intent, request_fields())

    with {:ok, template} <-
           AuthoringTemplateLookup.get_template(authoring_context(session), request),
         {:ok, rendered} <-
           InitialAuthoringDraftRenderer.render(template,
             state_machine_id: Map.get(intent, "state_machine_id"),
             initial_state: Map.get(intent, "initial_state"),
             revision: %{number: 1},
             tool: Map.get(intent, "tool")
           ),
         patch <- start_authoring_patch(session, intent, rendered),
         {:ok, _result} <- AuthoringDrafts.upsert_for_chat_session(session, patch) do
      :ok
    end
  end

  defp apply_authoring_intent(
         %ChatSession{} = session,
         %{"action" => "revise_authoring"} = intent
       ) do
    with {:ok, %{artifact: draft}} <-
           AuthoringDrafts.get_for_chat_session(session, Map.get(intent, "state_machine_id")),
         patch <- revise_authoring_patch(session, intent, draft),
         {:ok, _result} <- AuthoringDrafts.upsert_for_chat_session(session, patch) do
      :ok
    end
  end

  defp apply_authoring_intent(_session, _intent), do: {:error, :unsupported_authoring_action}

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
  end

  defp start_authoring_patch(%ChatSession{} = session, intent, rendered) do
    rendered.payload
    |> Map.merge(%{
      state_machine_id: rendered.state_machine_id,
      state_machine_entrypoint: rendered.state_machine_entrypoint,
      current_state: rendered.initial_state,
      revision: rendered.revision,
      source_chat: source_chat(session, intent, rendered.revision),
      template: rendered.template
    })
    |> maybe_put(:open_questions, Map.get(intent, "open_questions"))
  end

  defp revise_authoring_patch(%ChatSession{} = session, intent, %Artifact{} = draft) do
    revision = next_chat_feedback_revision(draft)

    %{
      state_machine_id: Map.get(intent, "state_machine_id"),
      current_state: Map.get(intent, "current_state"),
      revision: revision,
      source_chat: source_chat(session, intent, revision)
    }
    |> maybe_put(:candidate_work_units, Map.get(intent, "candidate_work_units"))
    |> maybe_put(:revision_notes, present_list(Map.get(intent, "feedback", "")))
  end

  defp source_chat(%ChatSession{} = session, intent, revision) do
    %{
      chat_session_id: session.id,
      source_message_id: Map.get(intent, "source_message_id"),
      turn_index: revision_value(revision)
    }
  end

  defp next_chat_feedback_revision(%Artifact{} = draft) do
    %{source: "chat_feedback", value: revision_value(draft.data["revision"]) + 1}
  end

  defp revision_value(%{"value" => value}) when is_integer(value), do: value
  defp revision_value(%{value: value}) when is_integer(value), do: value
  defp revision_value(value) when is_integer(value), do: value
  defp revision_value(_value), do: 0

  defp authoring_context(%ChatSession{} = session) do
    %{user_id: session.user_id, project_id: session.project_id}
  end

  defp request_fields do
    Enum.map(AuthoringTemplate.classification_fields(), &Atom.to_string/1)
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
