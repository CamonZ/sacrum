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
    tracker_task_write
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
      assert DirectTrackerOperationTools.known_function_name?("tracker_task_write")

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
      tool = tool_by_name("update_step_prompt")

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

    test "exposes tracker_task_write create as a branch of the resource-owned write tool" do
      assert %{
               "function" => %{
                 "parameters" => %{
                   "additionalProperties" => false,
                   "required" => required,
                   "properties" => properties
                 }
               }
             } = tool_by_name("tracker_task_write")

      assert Enum.sort(required) == ~w(operation title)
      assert properties["operation"]["enum"] == ["create"]

      assert Map.keys(properties) |> Enum.sort() ==
               ~w(depends_on_refs description level operation parent_ref priority tags title workflow_ref)

      assert properties["title"]["type"] == "string"
      assert properties["description"]["type"] == "string"
      assert properties["level"]["type"] == "string"
      assert properties["priority"]["type"] == "string"
      assert properties["tags"]["type"] == "array"
      assert properties["tags"]["items"]["type"] == "string"
      assert properties["parent_ref"]["type"] == "string"
      assert properties["depends_on_refs"]["type"] == "array"
      assert properties["depends_on_refs"]["items"]["type"] == "string"
      assert properties["workflow_ref"]["type"] == "string"
      refute Map.has_key?(properties, "needs_review")
      refute Map.has_key?(properties, "needs_human_review")
      refute Map.has_key?(properties, "review_comment")
    end

    test "does not advertise a standalone model-visible create tool" do
      tool_names =
        DirectTrackerOperationTools.all()
        |> Enum.map(&get_in(&1, ["function", "name"]))

      assert "tracker_task_write" in tool_names
      refute "create_task" in tool_names
      refute "create" in tool_names
      refute "tracker_task_create" in tool_names
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

  defp tool_by_name(name) do
    Enum.find(DirectTrackerOperationTools.all(), fn
      %{"function" => %{"name" => ^name}} -> true
      _tool -> false
    end)
  end
end
