defmodule Sacrum.Chat.Inference.Actions.OpenRouterChatTest do
  @moduledoc """
  Unit tests over `Sacrum.Chat.Inference.Actions.OpenRouterChat`'s
  Sacrum-owned helpers. The Jido action proper hits ReqLLM (and a real
  OpenRouter endpoint), so the tests here cover the pure transforms that
  matter for getting our authoring tools across the ReqLLM boundary.
  """

  use ExUnit.Case, async: true

  alias Sacrum.Chat.AuthoringTools
  alias Sacrum.Chat.Inference.Actions.OpenRouterChat

  describe "normalize_tools/1" do
    test "returns nil and [] unchanged" do
      assert OpenRouterChat.normalize_tools(nil) == nil
      assert OpenRouterChat.normalize_tools([]) == []
    end

    test "converts AuthoringTools.all/0 into ReqLLM.Tool structs whose to_schema round-trips" do
      tools = OpenRouterChat.normalize_tools(AuthoringTools.all())

      assert [%ReqLLM.Tool{name: "start_authoring"}, %ReqLLM.Tool{name: "revise_authoring"}] =
               tools

      schemas = Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai))

      assert [
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "start_authoring",
                   "parameters" => %{"required" => start_required}
                 }
               },
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "revise_authoring",
                   "parameters" => %{"required" => revise_required}
                 }
               }
             ] = schemas

      assert "run_kind" in start_required
      assert "state_machine_id" in revise_required
    end

    test "passes already-built %ReqLLM.Tool{} entries through unchanged" do
      tool =
        ReqLLM.Tool.new!(
          name: "manual",
          description: "manual",
          parameter_schema: %{"type" => "object", "properties" => %{}},
          callback: fn _ -> {:ok, :manual} end
        )

      assert [^tool] = OpenRouterChat.normalize_tools([tool])
    end
  end
end
