defmodule Sacrum.Chat.Inference.OpenRouterToolCallsTest do
  @moduledoc """
  Direct tests over the tool_call parsing path inside
  `Sacrum.Chat.Inference.OpenRouter`. Exercises the private
  `normalize_action_result/3` flow by reaching through it with synthesized
  ReqLLM-shaped results, since the only thing being tested is the pure mapping
  from action result -> Inference.Result.

  These cover Testing Criteria 2, 3 (parse side) and Failure Test 1 (unknown
  function names dropped without crashing).
  """

  use ExUnit.Case, async: false

  alias Sacrum.Chat.Inference.OpenRouter

  # Reach into the private normalizer via apply/3 with the same shape the
  # Jido action result carries (a plain map). This keeps the test focused on
  # the metadata mapping rather than the HTTP layer.
  defp normalize(result, source_message_id, config_overrides \\ %{}) do
    config =
      %{
        api_key: "sk-test",
        base_url: "https://openrouter.test",
        model: "fake-model",
        app_referer: nil,
        app_title: nil,
        reasoning_effort: nil,
        timeout: 120_000
      }
      |> Map.merge(config_overrides)

    apply(OpenRouter, :normalize_action_result, [result, config, source_message_id])
  end

  describe "tool_call parsing into authoring_tool_intent" do
    test "lifts start_authoring tool_call into internal_metadata with source_message_id" do
      action_result = %{
        text: "Drafting now.",
        model: "fake-model",
        usage: %{},
        finish_reason: "stop",
        provider_metadata: %{},
        tool_calls: [
          %{
            "function" => %{
              "name" => "start_authoring",
              "arguments" => %{
                "run_kind" => "code_factory",
                "artifact_type" => "workflow_draft",
                "template_kind" => "starter_draft",
                "state_machine_entrypoint" => "start_code_factory_creation",
                "state_machine_id" => "code_factory_creation",
                "initial_state" => "collect_workflow_goal"
              }
            }
          }
        ]
      }

      result = normalize(action_result, "msg-1")

      assert %{
               "authoring_tool_intent" => %{
                 "action" => "start_authoring",
                 "run_kind" => "code_factory",
                 "artifact_type" => "workflow_draft",
                 "template_kind" => "starter_draft",
                 "state_machine_entrypoint" => "start_code_factory_creation",
                 "state_machine_id" => "code_factory_creation",
                 "initial_state" => "collect_workflow_goal",
                 "source_message_id" => "msg-1"
               }
             } = result.internal_metadata
    end

    test "lifts revise_authoring tool_call with action and source_message_id" do
      action_result = %{
        text: "Revising the active draft.",
        model: "fake-model",
        usage: %{},
        finish_reason: "stop",
        provider_metadata: %{},
        tool_calls: [
          %{
            "function" => %{
              "name" => "revise_authoring",
              "arguments" => %{
                "state_machine_id" => "code_factory_creation",
                "current_state" => "refine_workflow_recipe",
                "feedback" => "Add a risk note section."
              }
            }
          }
        ]
      }

      result = normalize(action_result, "msg-99")

      assert %{
               "authoring_tool_intent" => %{
                 "action" => "revise_authoring",
                 "state_machine_id" => "code_factory_creation",
                 "current_state" => "refine_workflow_recipe",
                 "feedback" => "Add a risk note section.",
                 "source_message_id" => "msg-99"
               }
             } = result.internal_metadata
    end

    test "decodes JSON-string arguments from the provider" do
      action_result = %{
        text: "Drafting.",
        model: "fake-model",
        usage: %{},
        finish_reason: "stop",
        provider_metadata: %{},
        tool_calls: [
          %{
            "function" => %{
              "name" => "start_authoring",
              "arguments" =>
                Jason.encode!(%{
                  "run_kind" => "feature_exploration",
                  "artifact_type" => "task_draft",
                  "template_kind" => "starter_draft",
                  "state_machine_entrypoint" => "start_minimal_feature_exploration",
                  "state_machine_id" => "feature_exploration",
                  "initial_state" => "collect_feature_scope"
                })
            }
          }
        ]
      }

      result = normalize(action_result, "msg-42")

      assert result.internal_metadata["authoring_tool_intent"]["run_kind"] ==
               "feature_exploration"
    end

    test "omits authoring_tool_intent entirely when no tool_calls are present" do
      action_result = %{
        text: "Just a reply.",
        model: "fake-model",
        usage: %{},
        finish_reason: "stop",
        provider_metadata: %{},
        tool_calls: []
      }

      result = normalize(action_result, "msg-1")

      refute Map.has_key?(result.internal_metadata, "authoring_tool_intent")
    end

    test "synthesizes content when text is empty but a tool_call intent is present" do
      action_result = %{
        text: "",
        model: "fake-model",
        usage: %{},
        finish_reason: "tool_calls",
        provider_metadata: %{},
        tool_calls: [
          %{
            "function" => %{
              "name" => "start_authoring",
              "arguments" => %{
                "run_kind" => "feature_exploration",
                "artifact_type" => "task_draft",
                "template_kind" => "starter_draft",
                "state_machine_entrypoint" => "start_minimal_feature_exploration",
                "state_machine_id" => "feature_exploration",
                "initial_state" => "collect_feature_scope"
              }
            }
          }
        ]
      }

      result = normalize(action_result, "msg-empty")

      assert is_binary(result.content) and String.trim(result.content) != ""
      assert result.internal_metadata["authoring_tool_intent"]["action"] == "start_authoring"
    end

    test "keeps the first parallel authoring tool_call and logs about the extras" do
      action_result = %{
        text: "",
        model: "fake-model",
        usage: %{},
        finish_reason: "tool_calls",
        provider_metadata: %{},
        tool_calls: [
          %{
            "function" => %{
              "name" => "start_authoring",
              "arguments" => %{
                "run_kind" => "feature_exploration",
                "artifact_type" => "task_draft",
                "template_kind" => "starter_draft",
                "state_machine_entrypoint" => "start_minimal_feature_exploration",
                "state_machine_id" => "feature_exploration",
                "initial_state" => "collect_feature_scope"
              }
            }
          },
          %{
            "function" => %{
              "name" => "revise_authoring",
              "arguments" => %{"state_machine_id" => "feature_exploration"}
            }
          }
        ]
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = normalize(action_result, "msg-parallel")
          assert result.internal_metadata["authoring_tool_intent"]["action"] == "start_authoring"
        end)

      assert log =~ "received 2 authoring tool_calls"
    end

    test "ignores struct-shaped arguments instead of leaking __struct__" do
      action_result = %{
        text: "",
        model: "fake-model",
        usage: %{},
        finish_reason: "tool_calls",
        provider_metadata: %{},
        tool_calls: [
          %{
            "function" => %{
              "name" => "start_authoring",
              "arguments" => ~U[2026-05-23 12:00:00Z]
            }
          }
        ]
      }

      result = normalize(action_result, "msg-struct")
      intent = result.internal_metadata["authoring_tool_intent"]

      refute Map.has_key?(intent, "__struct__")
      assert intent["action"] == "start_authoring"
      assert intent["source_message_id"] == "msg-struct"
    end

    test "drops tool_calls with unknown function names and logs a warning" do
      action_result = %{
        text: "Tried.",
        model: "fake-model",
        usage: %{},
        finish_reason: "stop",
        provider_metadata: %{},
        tool_calls: [
          %{"function" => %{"name" => "execute_workflow", "arguments" => %{"foo" => "bar"}}}
        ]
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = normalize(action_result, "msg-1")
          refute Map.has_key?(result.internal_metadata, "authoring_tool_intent")
        end)

      assert log =~ "dropping tool_call for unknown function"
      assert log =~ "execute_workflow"
    end
  end
end
