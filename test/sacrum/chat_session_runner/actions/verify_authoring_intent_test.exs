defmodule Sacrum.ChatSessionRunner.Actions.VerifyAuthoringIntentTest do
  @moduledoc """
  Unit tests over the VerifyAuthoringIntent action's `verify/2` helper.

  These tests focus on the input -> output mapping for the inference result so
  we exercise:

    * pass-through when no authoring_tool_intent is present
    * rule-based rejection on hard schema failures (no LLM call)
    * verifier-driven rejection (with a fake verifier provider)
    * verifier-driven acceptance (with a fake verifier provider)
    * fail-closed on verifier error
  """

  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts.{LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.Actions.VerifyAuthoringIntent
  alias Sacrum.Repo.Schemas.ChatSession
  alias Sacrum.Repo.Users

  setup do
    original = Application.get_env(:sacrum, :authoring_verifier, [])
    on_exit(fn -> Application.put_env(:sacrum, :authoring_verifier, original) end)
    :ok
  end

  defp create_session do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "verify-intent-#{suffix}@example.com",
        username: "verify_intent_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user.id, %{name: "Verify Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})
    %{user: user, project: project, session: session}
  end

  defp result_with(intent) do
    %Result{
      content: "Drafting now.",
      content_format: :markdown,
      public_metadata: %{},
      internal_metadata: if(intent, do: %{"authoring_tool_intent" => intent}, else: %{})
    }
  end

  defp valid_start_authoring_intent do
    %{
      "action" => "start_authoring",
      "run_kind" => "code_factory",
      "artifact_type" => "workflow_draft",
      "template_kind" => "starter_draft",
      "state_machine_entrypoint" => "start_code_factory_creation",
      "state_machine_id" => "code_factory_creation",
      "initial_state" => "collect_workflow_goal",
      "source_message_id" => "msg-1"
    }
  end

  defmodule SufficientVerifier do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(_messages, _opts) do
      {:ok,
       %Result{
         content:
           Jason.encode!(%{
             "sufficient" => true,
             "missing" => [],
             "open_questions" => [],
             "reasoning" => "Looks good."
           }),
         content_format: :markdown,
         public_metadata: %{"provider" => "verifier-fake"},
         internal_metadata: %{}
       }}
    end
  end

  defmodule InsufficientVerifier do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(_messages, _opts) do
      {:ok,
       %Result{
         content:
           Jason.encode!(%{
             "sufficient" => false,
             "missing" => ["scope"],
             "open_questions" => ["What user outcome is the priority?"],
             "reasoning" => "Transcript too thin."
           }),
         content_format: :markdown,
         public_metadata: %{},
         internal_metadata: %{}
       }}
    end
  end

  defmodule ErroringVerifier do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(_messages, _opts), do: {:error, :verifier_timeout}
  end

  describe "verify/2 with no authoring_tool_intent" do
    test "passes the inference result through unchanged" do
      %{session: session} = create_session()
      result = result_with(nil)

      assert {:ok, ^result} = VerifyAuthoringIntent.verify(session, result)
    end
  end

  describe "verify/2 with rule-based rejection" do
    test "rejects start_authoring when run_kind is unknown without calling the verifier" do
      %{session: session} = create_session()

      bad_intent =
        valid_start_authoring_intent()
        |> Map.put("run_kind", "totally_made_up_kind")
        |> Map.put("state_machine_id", "totally_made_up_kind")

      Application.put_env(:sacrum, :authoring_verifier,
        enabled: true,
        provider: __MODULE__.ErroringVerifier
      )

      assert {:ok, %Result{} = next} =
               VerifyAuthoringIntent.verify(%ChatSession{} = session, result_with(bad_intent))

      refute Map.has_key?(next.internal_metadata, "authoring_tool_intent")

      assert next.internal_metadata["authoring_tool_intent_rejected"]["reason"] ==
               "schema_check_failed"

      assert next.content =~ "Vertebrae"
    end

    test "rejects start_authoring when required fields are missing" do
      %{session: session} = create_session()

      bad_intent =
        valid_start_authoring_intent()
        |> Map.delete("initial_state")

      assert {:ok, %Result{} = next} =
               VerifyAuthoringIntent.verify(session, result_with(bad_intent))

      refute Map.has_key?(next.internal_metadata, "authoring_tool_intent")

      assert next.internal_metadata["authoring_tool_intent_rejected"]["reason"] ==
               "schema_check_failed"
    end

    test "rejects start_authoring when required fields are present but empty/wrong type" do
      %{session: session} = create_session()

      for bad_value <- ["", 0, [], %{}] do
        bad_intent = Map.put(valid_start_authoring_intent(), "state_machine_id", bad_value)

        assert {:ok, %Result{} = next} =
                 VerifyAuthoringIntent.verify(session, result_with(bad_intent))

        refute Map.has_key?(next.internal_metadata, "authoring_tool_intent")

        assert next.internal_metadata["authoring_tool_intent_rejected"]["reason"] ==
                 "schema_check_failed"
      end
    end

    test "rejects without crashing when run_kind is not a string" do
      %{session: session} = create_session()

      for bad_run_kind <- [nil, 0, :code_factory, ["code_factory"]] do
        bad_intent = Map.put(valid_start_authoring_intent(), "run_kind", bad_run_kind)

        assert {:ok, %Result{} = next} =
                 VerifyAuthoringIntent.verify(session, result_with(bad_intent))

        refute Map.has_key?(next.internal_metadata, "authoring_tool_intent")

        assert next.internal_metadata["authoring_tool_intent_rejected"]["reason"] ==
                 "schema_check_failed"
      end
    end
  end

  describe "verify/2 with verifier enabled" do
    test "strips the intent when verifier reports sufficient=false and rewrites content" do
      %{session: session} = create_session()

      Application.put_env(:sacrum, :authoring_verifier,
        enabled: true,
        provider: __MODULE__.InsufficientVerifier,
        transcript_loader: fn _session -> [%{role: "user", content: "hi"}] end
      )

      assert {:ok, %Result{} = next} =
               VerifyAuthoringIntent.verify(session, result_with(valid_start_authoring_intent()))

      refute Map.has_key?(next.internal_metadata, "authoring_tool_intent")

      assert next.internal_metadata["authoring_tool_intent_rejected"]["reason"] ==
               "verifier_insufficient"

      assert next.content =~ "What user outcome is the priority?"
    end

    test "passes the intent through unchanged when verifier reports sufficient=true" do
      %{session: session} = create_session()

      Application.put_env(:sacrum, :authoring_verifier,
        enabled: true,
        provider: __MODULE__.SufficientVerifier,
        transcript_loader: fn _session -> [%{role: "user", content: "hi"}] end
      )

      intent = valid_start_authoring_intent()
      input = result_with(intent)

      assert {:ok, %Result{} = next} = VerifyAuthoringIntent.verify(session, input)

      assert next.internal_metadata["authoring_tool_intent"] == intent
      refute Map.has_key?(next.internal_metadata, "authoring_tool_intent_rejected")
    end

    test "treats the intent as rejected (fail-closed) when the verifier call errors" do
      %{session: session} = create_session()

      Application.put_env(:sacrum, :authoring_verifier,
        enabled: true,
        provider: __MODULE__.ErroringVerifier,
        transcript_loader: fn _session -> [%{role: "user", content: "hi"}] end
      )

      assert {:ok, %Result{} = next} =
               VerifyAuthoringIntent.verify(session, result_with(valid_start_authoring_intent()))

      refute Map.has_key?(next.internal_metadata, "authoring_tool_intent")

      assert next.internal_metadata["authoring_tool_intent_rejected"]["reason"] ==
               "verifier_error"

      assert next.content =~ "could not verify"
    end
  end

  describe "verify/2 with verifier disabled (default)" do
    test "lets schema-pass intents through unchanged" do
      %{session: session} = create_session()
      Application.put_env(:sacrum, :authoring_verifier, enabled: false)

      intent = valid_start_authoring_intent()

      assert {:ok, %Result{} = next} =
               VerifyAuthoringIntent.verify(session, result_with(intent))

      assert next.internal_metadata["authoring_tool_intent"] == intent
    end
  end
end
