defmodule Sacrum.Accounts.AuthoringChatLoop do
  @moduledoc """
  Inference-driven authoring state machine for live-chat prototypes.

  Inference metadata only drives inspectable authoring draft state. This
  module does not create workflows, tickets, task records, validation
  results, apply records, or GUI command events.
  """

  alias Sacrum.Accounts.{AuthoringDrafts, AuthoringTemplateLookup, InitialAuthoringDraftRenderer}
  alias Sacrum.Chat.Inference
  alias Sacrum.Repo.Schemas.{Artifact, AuthoringTemplate, ChatSession}

  @doc """
  Post-assistant authoring hook. Every chat pipeline that appends an assistant
  message must invoke this after persisting the message and inference_completed
  event, so authoring tool intents in the inference metadata produce drafts.
  """
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
    |> maybe_put(:trigger, Map.get(rendered, :trigger))
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

  defp present_list(""), do: []
  defp present_list(value), do: [value]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
