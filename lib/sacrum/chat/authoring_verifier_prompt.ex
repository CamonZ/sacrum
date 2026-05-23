defmodule Sacrum.Chat.AuthoringVerifierPrompt do
  @moduledoc """
  Verifier prompt builder for the Vertebrae authoring loop.

  Given (transcript, proposed_intent, active_draft), this module produces a
  pair of `{system_prompt, response_format}` suitable for the verifier
  inference call. The verifier's job is to judge whether the transcript
  contains enough context for the proposed start_authoring or revise_authoring
  intent.

  The verifier MUST return a structured JSON verdict matching:

    {
      "sufficient": boolean,
      "missing": [string],
      "open_questions": [string],
      "reasoning": string
    }

  Like the authoring system prompt, the verifier prompt uses the outward-facing
  product name "Vertebrae" and never references the internal name "Sacrum".
  """

  alias Sacrum.Repo.Schemas.Artifact

  @json_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["sufficient", "missing", "open_questions", "reasoning"],
    "properties" => %{
      "sufficient" => %{
        "type" => "boolean",
        "description" =>
          "Whether the transcript provides enough context to justify the proposed intent."
      },
      "missing" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Information categories still missing from the transcript."
      },
      "open_questions" => %{
        "type" => "array",
        "items" => %{"type" => "string"},
        "description" => "Clarifying questions to ask the user before the intent can be accepted."
      },
      "reasoning" => %{
        "type" => "string",
        "description" => "Brief justification for the verdict."
      }
    }
  }

  @doc """
  Build the verifier system prompt text from a transcript, proposed intent,
  and an optional active draft.
  """
  @spec build(list(), map(), Artifact.t() | map() | nil) :: String.t()
  def build(transcript, proposed_intent, active_draft \\ nil)
      when is_list(transcript) and is_map(proposed_intent) do
    Enum.join(
      [
        header(),
        "",
        "## Proposed intent",
        format_proposed_intent(proposed_intent),
        "",
        "## Active draft",
        format_active_draft(active_draft),
        "",
        "## Transcript",
        format_transcript(transcript),
        "",
        "## Response format",
        response_format_description()
      ],
      "\n"
    )
  end

  @doc """
  Return the JSON schema response_format payload (OpenAI shape) for the verifier.
  """
  @spec response_format() :: map()
  def response_format do
    %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "vertebrae_authoring_verifier_verdict",
        "strict" => true,
        "schema" => @json_schema
      }
    }
  end

  @spec json_schema() :: map()
  def json_schema, do: @json_schema

  defp header do
    String.trim_trailing("""
    You are the Vertebrae authoring verifier. Another model has proposed an
    authoring intent (either start_authoring or revise_authoring) based on the
    chat transcript below. Your job is to verify, conservatively, whether the
    transcript already contains enough context to justify the proposed intent.

    You do not produce new intents. You only accept or reject the proposed one.
    Bias toward rejecting when the transcript is thin or the proposed intent
    invents facts the user has not stated.
    """)
  end

  defp format_proposed_intent(intent) do
    intent
    |> Map.delete("source_message_id")
    |> stable_inspect()
  end

  defp format_active_draft(nil), do: "(no active draft)"

  defp format_active_draft(%Artifact{data: data}), do: format_active_draft(data || %{})

  defp format_active_draft(%{} = data) do
    data
    |> Map.take(["state_machine_id", "current_state", "revision", "open_questions"])
    |> stable_inspect()
  end

  defp format_transcript(messages) do
    Enum.map_join(messages, "\n", &format_message/1)
  end

  defp format_message(%{role: role, content: content}) when is_atom(role) and not is_nil(role),
    do: format_message(%{role: Atom.to_string(role), content: content})

  defp format_message(%{role: role, content: content}) when is_binary(role),
    do: "#{role}: #{content}"

  defp format_message(%{"role" => role, "content" => content}), do: "#{role}: #{content}"
  defp format_message(other), do: inspect(other)

  defp response_format_description do
    String.trim_trailing("""
    Return a single JSON object matching this schema:

      sufficient: boolean
      missing: array of short strings naming categories of missing context
      open_questions: array of clarifying questions to ask the user
      reasoning: short justification

    Do not include any other top-level keys.
    """)
  end

  defp stable_inspect(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> encoded
      _ -> inspect(value)
    end
  end
end
