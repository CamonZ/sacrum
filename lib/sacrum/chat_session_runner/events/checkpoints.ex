defmodule Sacrum.ChatSessionRunner.Events.Checkpoints do
  @moduledoc """
  Owns idempotent public/internal runner checkpoint events.
  """

  import Ecto.Query

  alias Sacrum.Accounts.ChatEvents
  alias Sacrum.Chat.Inference
  alias Sacrum.ChatSessionRunner.Session.Turn
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatSession}

  @runner_version 1
  @public_payload_keys ~w(status message_count assistant_message_id resumed provider model turn_message_id)
  @ordered_steps [
    :intake,
    :load_messages,
    :invoke_inference,
    :continue_inference,
    :append_assistant,
    :complete_session,
    :failed
  ]
  @step_event_types Map.new(@ordered_steps, &{"chat_session_runner.#{&1}.completed", &1})

  @spec checkpoint_step(ChatSession.t(), atom(), map()) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  def checkpoint_step(%ChatSession{} = session, step, details)
      when is_atom(step) and is_map(details) do
    event_type = "chat_session_runner.#{step}.completed"
    details = Map.put_new(details, "turn_message_id", Turn.latest_user_message_id!(session))
    public_payload = runner_public_payload(session, step, details)

    internal_payload =
      Inference.scrub_secrets(%{
        "runner" => "chat_session_runner",
        "runner_version" => @runner_version,
        "step" => Atom.to_string(step),
        "details" => details
      })

    with {:ok, public_event} <-
           ensure_event(session, event_type, :public, public_payload, %{}),
         {:ok, internal_event} <-
           ensure_event(session, event_type, :internal, %{}, internal_payload) do
      {:ok, [public_event, internal_event]}
    end
  end

  @spec recorded_steps_for_turn(ChatSession.t(), String.t()) :: [atom()]
  def recorded_steps_for_turn(%ChatSession{} = session, turn_message_id)
      when is_binary(turn_message_id) do
    event_types = Map.keys(@step_event_types)

    query =
      from event in ChatEvent,
        where:
          event.user_id == ^session.user_id and event.project_id == ^session.project_id and
            event.chat_session_id == ^session.id and event.visibility == :public and
            event.event_type in ^event_types and
            fragment("?->>'turn_message_id' = ?", event.public_payload, ^turn_message_id),
        select: event.event_type

    query
    |> Repo.all()
    |> Enum.map(&Map.fetch!(@step_event_types, &1))
  end

  @spec last_recorded_step([atom()]) :: atom() | nil
  def last_recorded_step(steps) when is_list(steps) do
    Enum.find(Enum.reverse(@ordered_steps), &(&1 in steps))
  end

  @spec runner_public_payload(ChatSession.t(), atom(), map()) :: map()
  defp runner_public_payload(%ChatSession{} = session, step, details) do
    details
    |> Map.take(@public_payload_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(%{
      "chat_session_id" => session.id,
      "step" => Atom.to_string(step)
    })
  end

  @spec ensure_event(ChatSession.t(), String.t(), :public | :internal, map(), map()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  defp ensure_event(
         %ChatSession{} = session,
         event_type,
         visibility,
         public_payload,
         internal_payload
       ) do
    case get_checkpoint_event(session, event_type, visibility, public_payload, internal_payload) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        attrs = %{
          event_type: event_type,
          visibility: visibility,
          public_payload: public_payload,
          internal_payload: internal_payload
        }

        ChatEvents.append_to_session(session, attrs)
    end
  end

  @spec get_checkpoint_event(ChatSession.t(), String.t(), :public | :internal, map(), map()) ::
          {:ok, ChatEvent.t()} | {:error, :not_found}
  defp get_checkpoint_event(session, event_type, visibility, public_payload, internal_payload) do
    turn_message_id =
      public_payload["turn_message_id"] ||
        get_in(internal_payload, ["details", "turn_message_id"])

    if turn_message_id do
      get_checkpoint_event_for_turn(session, event_type, visibility, turn_message_id)
    else
      ChatEvents.get_by_type(session, event_type, visibility)
    end
  end

  @spec get_checkpoint_event_for_turn(
          ChatSession.t(),
          String.t(),
          :public | :internal,
          String.t()
        ) ::
          {:ok, ChatEvent.t()} | {:error, :not_found}
  defp get_checkpoint_event_for_turn(session, event_type, visibility, turn_message_id) do
    query =
      from event in ChatEvent,
        where:
          event.user_id == ^session.user_id and event.project_id == ^session.project_id and
            event.chat_session_id == ^session.id and event.event_type == ^event_type and
            event.visibility == ^visibility and
            (fragment("?->>'turn_message_id' = ?", event.public_payload, ^turn_message_id) or
               fragment(
                 "?->'details'->>'turn_message_id' = ?",
                 event.internal_payload,
                 ^turn_message_id
               )),
        order_by: [asc: event.inserted_at, asc: event.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end
end
