defmodule Sacrum.Chat.AuthoringTools do
  @moduledoc """
  OpenAI-shaped function tool definitions for Vertebrae authoring.

  Two tools are exposed to the chat model:

    * `start_authoring` — request that Vertebrae render a brand-new authoring
      draft for one of the four known run kinds.
    * `revise_authoring` — request that Vertebrae update the active authoring
      draft referenced by `state_machine_id`.

  These specs are the source of truth for both the OpenRouter `tools` payload
  and the rule-based schema check inside
  `Sacrum.ChatSessionRunner.Actions.VerifyAuthoringIntent`.
  """

  alias Sacrum.Accounts.AuthoringRunKinds

  @start_authoring_name "start_authoring"
  @revise_authoring_name "revise_authoring"

  @spec known_function_name?(String.t()) :: boolean()
  def known_function_name?(name) when is_binary(name),
    do: name in [@start_authoring_name, @revise_authoring_name]

  def known_function_name?(_), do: false

  @doc """
  Return both tool definitions in OpenAI tool format.
  """
  @spec all() :: [map()]
  def all, do: [start_authoring(), revise_authoring()]

  @spec start_authoring() :: map()
  def start_authoring do
    %{
      "type" => "function",
      "function" => %{
        "name" => @start_authoring_name,
        "description" =>
          "Ask Vertebrae to create a new authoring draft for one of the four run kinds. " <>
            "Only call this when no active draft exists for the chosen state_machine_id.",
        "parameters" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => required_start_authoring_keys(),
          "properties" => %{
            "run_kind" => %{
              "type" => "string",
              "enum" => AuthoringRunKinds.run_kinds(),
              "description" => "Which Vertebrae authoring run kind to start."
            },
            "artifact_type" => %{
              "type" => "string",
              "enum" => AuthoringRunKinds.artifact_types(),
              "description" => "Artifact type the run kind produces."
            },
            "template_kind" => %{
              "type" => "string",
              "enum" => AuthoringRunKinds.template_kinds(),
              "description" => "Authoring template kind that seeds the draft."
            },
            "state_machine_entrypoint" => %{
              "type" => "string",
              "enum" => AuthoringRunKinds.state_machine_entrypoints(),
              "description" => "Entrypoint identifier for the run-kind state machine."
            },
            "state_machine_id" => %{
              "type" => "string",
              "enum" => AuthoringRunKinds.state_machine_ids(),
              "description" => "Stable state-machine id for this draft."
            },
            "initial_state" => %{
              "type" => "string",
              "enum" => AuthoringRunKinds.initial_states(),
              "description" => "Initial state for the draft. Must match the run kind."
            },
            "candidate_work_units" => %{
              "type" => "array",
              "description" =>
                "Optional candidate work units to seed the draft with. Use the user's wording.",
              "items" => %{"type" => "object"}
            },
            "open_questions" => %{
              "type" => "array",
              "description" => "Outstanding clarifying questions about the proposed work.",
              "items" => %{"type" => "string"}
            }
          }
        }
      }
    }
  end

  @spec revise_authoring() :: map()
  def revise_authoring do
    %{
      "type" => "function",
      "function" => %{
        "name" => @revise_authoring_name,
        "description" =>
          "Ask Vertebrae to revise the active authoring draft referenced by state_machine_id.",
        "parameters" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["state_machine_id"],
          "properties" => %{
            "state_machine_id" => %{
              "type" => "string",
              "enum" => AuthoringRunKinds.state_machine_ids(),
              "description" => "The stable state-machine id of the draft to revise."
            },
            "current_state" => %{
              "type" => "string",
              "description" => "Updated current state for the draft."
            },
            "candidate_work_units" => %{
              "type" => "array",
              "description" => "Replacement or additional candidate work units for the draft.",
              "items" => %{"type" => "object"}
            },
            "feedback" => %{
              "type" => "string",
              "description" =>
                "Plain-language feedback from the user that motivates this revision."
            },
            "open_questions" => %{
              "type" => "array",
              "description" => "Outstanding clarifying questions after this revision.",
              "items" => %{"type" => "string"}
            }
          }
        }
      }
    }
  end

  @doc """
  Return the list of required argument keys for the named function.
  Returns `:error` for unknown functions.
  """
  @spec required_keys(String.t()) :: {:ok, [String.t()]} | :error
  def required_keys(@start_authoring_name), do: {:ok, required_start_authoring_keys()}
  def required_keys(@revise_authoring_name), do: {:ok, ["state_machine_id"]}
  def required_keys(_), do: :error

  defp required_start_authoring_keys do
    ~w(run_kind artifact_type template_kind state_machine_entrypoint state_machine_id initial_state)
  end
end
