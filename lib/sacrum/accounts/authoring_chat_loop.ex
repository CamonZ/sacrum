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

  @feature_exploration "feature_exploration"
  @feature_exploration_revise_intent %{
    "state_machine_id" => @feature_exploration,
    "current_state" => "refine_feature_scope",
    assistant_prefix: "I updated the feature exploration draft with:"
  }
  @tool_start_authoring_intents %{
    "authoring.start_feature_exploration" => %{
      request: %{
        "run_kind" => "feature_exploration",
        "artifact_type" => "task_draft",
        "template_kind" => "starter_draft",
        "state_machine_entrypoint" => "start_minimal_feature_exploration",
        "state_machine_id" => @feature_exploration,
        "initial_state" => "collect_feature_scope"
      },
      assistant_prefix: "I started a feature exploration draft."
    }
  }
  @tool_revise_authoring_intents Map.new(
                                   ~w(
                                     authoring.continue_feature_exploration
                                     authoring.resume_feature_exploration
                                     authoring.revise_feature_exploration
                                   ),
                                   &{&1, @feature_exploration_revise_intent}
                                 )

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
         {:ok, draft, assistant_text} <- apply_tool_intent(session, intent, opts) do
      state = state_from_draft(draft)
      response = %{assistant_text: assistant_text, draft: draft, state: state}

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

  defp apply_tool_intent(%ChatSession{} = session, %{"name" => name} = intent, opts) do
    case fetch_tool_start_authoring_intent(name) do
      {:ok, entrypoint} -> start_tool_authoring(session, entrypoint, intent, opts)
      {:error, :not_found} -> revise_tool_authoring(session, intent, opts)
    end
  end

  defp apply_tool_intent(_session, _intent, _opts),
    do: {:error, :unsupported_authoring_intent}

  defp start_tool_authoring(%ChatSession{} = session, entrypoint, intent, opts) do
    arguments = arguments(intent)

    authoring_intent =
      Map.merge(entrypoint.request, %{
        "action" => "start_authoring",
        "source_message_id" => Keyword.get(opts, :source_message_id),
        "open_questions" => list_argument(arguments, "unknowns")
      })

    with {:ok, %{artifact: draft, patch: patch}} <- start_authoring(session, authoring_intent) do
      {:ok, draft,
       start_authoring_text(entrypoint.assistant_prefix, Map.get(patch, :open_questions, []))}
    end
  end

  defp revise_tool_authoring(%ChatSession{} = session, %{"name" => name} = intent, opts) do
    response = string_argument(arguments(intent), "response")

    with {:ok, entrypoint} <- fetch_tool_revise_authoring_intent(name),
         authoring_intent <-
           Map.merge(entrypoint, %{
             "action" => "revise_authoring",
             "source_message_id" => Keyword.get(opts, :source_message_id),
             "feedback" => response
           }),
         {:ok, %{artifact: draft}} <- revise_authoring(session, authoring_intent) do
      {:ok, draft, "#{entrypoint.assistant_prefix} #{response}"}
    end
  end

  defp revise_tool_authoring(_session, _intent, _opts),
    do: {:error, :unsupported_authoring_intent}

  defp apply_authoring_intent(%ChatSession{} = session, %{"action" => "start_authoring"} = intent) do
    with {:ok, _result} <- start_authoring(session, intent) do
      :ok
    end
  end

  defp apply_authoring_intent(
         %ChatSession{} = session,
         %{"action" => "revise_authoring"} = intent
       ) do
    with {:ok, _result} <- revise_authoring(session, intent) do
      :ok
    end
  end

  defp apply_authoring_intent(_session, _intent), do: {:error, :unsupported_authoring_action}

  defp start_authoring(%ChatSession{} = session, intent) do
    with {:ok, rendered} <- render_initial_authoring(session, intent),
         patch <- start_authoring_patch(session, intent, rendered),
         patch <- preserve_existing_revision(session, intent, patch),
         {:ok, %{artifact: draft}} <- AuthoringDrafts.upsert_for_chat_session(session, patch) do
      {:ok, %{artifact: draft, patch: patch}}
    end
  end

  defp preserve_existing_revision(session, intent, patch) do
    case AuthoringDrafts.get_for_chat_session(session, Map.get(intent, "state_machine_id")) do
      {:ok, _existing} -> Map.delete(patch, :revision)
      {:error, :not_found} -> patch
    end
  end

  defp revise_authoring(%ChatSession{} = session, intent) do
    with {:ok, state_machine_id} <- fetch_intent_string(intent, "state_machine_id"),
         {:ok, %{artifact: draft}} <-
           AuthoringDrafts.get_for_chat_session(session, state_machine_id),
         patch <- revise_authoring_patch(session, intent, draft),
         {:ok, %{artifact: revised_draft}} <-
           AuthoringDrafts.upsert_for_chat_session(session, patch) do
      {:ok, %{artifact: revised_draft, patch: patch}}
    end
  end

  defp render_initial_authoring(%ChatSession{} = session, intent) do
    request = Map.take(intent, request_fields())

    with {:ok, template} <-
           AuthoringTemplateLookup.get_template_for_session(session, request) do
      InitialAuthoringDraftRenderer.render(template,
        state_machine_id: Map.get(intent, "state_machine_id"),
        initial_state: Map.get(intent, "initial_state"),
        revision: %{number: 1},
        tool: Map.get(intent, "tool")
      )
    end
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

  defp request_fields do
    Enum.map(AuthoringTemplate.classification_fields(), &Atom.to_string/1)
  end

  defp fetch_intent_string(intent, key) do
    case Map.get(intent, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_intent_field, key}}
    end
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

  defp fetch_tool_start_authoring_intent(name) do
    fetch_tool_intent(@tool_start_authoring_intents, name, :not_found)
  end

  defp fetch_tool_revise_authoring_intent(name) do
    fetch_tool_intent(@tool_revise_authoring_intents, name, :unsupported_authoring_intent)
  end

  defp fetch_tool_intent(intents, name, missing_reason) do
    case Map.fetch(intents, name) do
      {:ok, entrypoint} -> {:ok, entrypoint}
      :error -> {:error, missing_reason}
    end
  end

  defp start_authoring_text(prefix, [question | _rest]) do
    "#{prefix} #{question}"
  end

  defp start_authoring_text(prefix, []) do
    "#{prefix} What outcome should this improve first?"
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
