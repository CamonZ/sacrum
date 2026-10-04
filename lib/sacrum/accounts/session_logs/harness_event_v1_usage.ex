defmodule Sacrum.Accounts.SessionLogs.HarnessEventV1Usage do
  alias Sacrum.Accounts.SessionLogs.HarnessEventV1

  @moduledoc """
  Extracts validated rollup counters from the provider-neutral HarnessEventV1 envelope.

  Only the top-level V1 `usage` payload is considered. Provider payload shapes
  and usage nested in terminal outcome events are intentionally ignored.
  """

  alias Sacrum.Repo.Schemas.SessionLog

  @enforce_keys [:event_id, :stream_id, :sequence]
  defstruct [:event_id, :stream_id, :sequence, :turn_delta, :session_snapshot]

  @type token_usage :: %{
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer()
        }

  @type usage :: %{
          required(:tokens) => token_usage(),
          optional(:context_tokens) => non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          event_id: String.t(),
          stream_id: String.t(),
          sequence: pos_integer(),
          turn_delta: usage() | nil,
          session_snapshot: usage() | nil
        }

  @spec parse(SessionLog.t()) :: {:ok, t()} | :error
  def parse(%SessionLog{format: "harness", content: content, logical_key: logical_key}) do
    case HarnessEventV1.decode(content, logical_key) do
      {:ok, event} ->
        {turn_delta, session_snapshot} = payload_usage(event["type"], event["data"])

        {:ok,
         %__MODULE__{
           event_id: event["event_id"],
           stream_id: event["stream_id"],
           sequence: event["sequence"],
           turn_delta: turn_delta,
           session_snapshot: session_snapshot
         }}

      :error ->
        :error
    end
  end

  def parse(%SessionLog{}), do: :error

  defp payload_usage("usage", data) do
    {usage(data["turn_delta"]), usage(data["session_snapshot"])}
  end

  defp payload_usage(_type, _data), do: {nil, nil}

  defp usage(nil), do: nil

  defp usage(value) do
    tokens = value["tokens"]

    %{
      tokens: %{
        input_tokens: tokens["input_tokens"],
        cached_input_tokens: tokens["cached_input_tokens"],
        output_tokens: tokens["output_tokens"]
      },
      context_tokens: value["context_tokens"]
    }
  end
end
