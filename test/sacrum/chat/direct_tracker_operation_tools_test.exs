defmodule Sacrum.Chat.DirectTrackerOperationToolsTest do
  @moduledoc """
  Contract tests for the server-owned direct tracker operation catalog exposed
  to live chat models. These tests intentionally target the catalog boundary,
  not execution.
  """

  use ExUnit.Case, async: true

  alias Sacrum.Chat.DirectTrackerOperationTools

  @expected_tool_names ~w(
    show_task
    read_task_sections
    update_task_fields
    upsert_task_section
    update_workflow_step
    update_step_prompt
    add_task_dependency
    remove_task_dependency
    move_task_to_workflow_step
  )

  @server_owned_fields ~w(
    user_id
    project_id
    permission
    permissions
    active_selection
    selected_task_id
    selected_workflow_id
    durable_object_id
    chat_session_id
  )

  describe "all/0" do
    test "returns only supported direct-operation schemas" do
      tools = DirectTrackerOperationTools.all()
      names = Enum.map(tools, &get_in(&1, ["function", "name"]))

      assert Enum.sort(names) == Enum.sort(@expected_tool_names)

      for tool <- tools do
        assert %{
                 "type" => "function",
                 "function" => %{
                   "name" => name,
                   "parameters" => %{
                     "type" => "object",
                     "additionalProperties" => false,
                     "properties" => properties
                   }
                 }
               } = tool

        assert name in @expected_tool_names
        assert is_map(properties)
      end
    end

    test "is separate from authoring tools" do
      direct_names =
        DirectTrackerOperationTools.all()
        |> Enum.map(&get_in(&1, ["function", "name"]))

      authoring_names =
        Sacrum.Chat.AuthoringTools.all()
        |> Enum.map(&get_in(&1, ["function", "name"]))

      assert direct_names != []
      assert MapSet.disjoint?(MapSet.new(direct_names), MapSet.new(authoring_names))
    end
  end

  describe "known_function_name?/1" do
    test "accepts supported direct operations and rejects unknown tool names" do
      assert DirectTrackerOperationTools.known_function_name?("show_task")
      assert DirectTrackerOperationTools.known_function_name?("update_task_fields")
      assert DirectTrackerOperationTools.known_function_name?("move_task_to_workflow_step")
      assert DirectTrackerOperationTools.known_function_name?("update_step_prompt")

      refute DirectTrackerOperationTools.known_function_name?("start_authoring")
      refute DirectTrackerOperationTools.known_function_name?("execute_shell")
      refute DirectTrackerOperationTools.known_function_name?(nil)
    end
  end

  describe "required_keys/1" do
    test "rejects unknown tool names before execution" do
      assert DirectTrackerOperationTools.required_keys("delete_everything") == :error
      assert DirectTrackerOperationTools.required_keys("start_authoring") == :error
    end

    test "does not require server-owned or context-derived fields from model arguments" do
      for tool_name <- @expected_tool_names do
        assert {:ok, required_keys} = DirectTrackerOperationTools.required_keys(tool_name)

        refute Enum.any?(required_keys, &(&1 in @server_owned_fields)),
               "#{tool_name} requires a server-owned field: #{inspect(required_keys)}"
      end
    end
  end

  describe "schemas" do
    test "exposes update_step_prompt as a prompt-only direct operation" do
      tool =
        DirectTrackerOperationTools.all()
        |> Enum.find(&(get_in(&1, ["function", "name"]) == "update_step_prompt"))

      assert %{
               "function" => %{
                 "parameters" => %{
                   "required" => ["prompt"],
                   "properties" => properties,
                   "additionalProperties" => false
                 }
               }
             } = tool

      assert Map.keys(properties) == ["prompt"]
      assert properties["prompt"]["type"] == "string"
    end

    test "do not expose server-owned or context-derived fields as model parameters" do
      for tool <- DirectTrackerOperationTools.all() do
        tool_name = get_in(tool, ["function", "name"])
        properties = get_in(tool, ["function", "parameters", "properties"]) || %{}

        refute Enum.any?(Map.keys(properties), &(&1 in @server_owned_fields)),
               "#{tool_name} exposes server-owned fields: #{inspect(Map.keys(properties))}"
      end
    end
  end
end
