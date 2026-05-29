defmodule Sacrum.Chat.DirectTrackerOperationTools do
  @moduledoc """
  Server-owned direct tracker operation tool definitions for live chat.

  These tools describe concrete tracker reads and edits the model may request.
  They are intentionally separate from `Sacrum.Chat.AuthoringTools` so direct
  tracker operations do not enter the authoring draft flow.
  """

  @server_owned_argument_keys ~w(
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

  @tools [
    {"show_task", "Read a single tracker task.", ~w(task_ref),
     %{
       "task_ref" => %{
         "type" => "string",
         "description" => "Task UUID or accepted short reference."
       },
       "include_sections" => %{"type" => "boolean"}
     }},
    {"read_task_sections", "Read tracker task sections.", ~w(task_ref),
     %{
       "task_ref" => %{
         "type" => "string",
         "description" => "Task UUID or accepted short reference."
       },
       "section_type" => %{"type" => "string"}
     }},
    {"update_task_fields", "Request updates to editable task fields.", ~w(task_ref fields),
     %{
       "task_ref" => %{
         "type" => "string",
         "description" => "Task UUID or accepted short reference."
       },
       "fields" => %{"type" => "object", "description" => "Task fields to update."}
     }},
    {"upsert_task_section", "Request creating or replacing a task section.",
     ~w(task_ref section_type content),
     %{
       "task_ref" => %{
         "type" => "string",
         "description" => "Task UUID or accepted short reference."
       },
       "section_type" => %{"type" => "string"},
       "content" => %{"type" => "string"}
     }},
    {"update_workflow_step", "Request prompt, goal, or configuration edits for a workflow step.",
     ~w(workflow_ref step_ref fields),
     %{
       "workflow_ref" => %{
         "type" => "string",
         "description" => "Workflow UUID or accepted short reference."
       },
       "step_ref" => %{"type" => "string", "description" => "Workflow step UUID, slug, or name."},
       "fields" => %{
         "type" => "object",
         "description" => "Step prompt, goal, or configuration fields to update."
       }
     }},
    {"update_step_prompt", "Request a prompt-only edit for the active workflow step.", ~w(prompt),
     %{
       "prompt" => %{"type" => "string"}
     }},
    {"add_task_dependency", "Request adding a dependency between two tasks.",
     ~w(task_ref depends_on_ref),
     %{
       "task_ref" => %{"type" => "string", "description" => "Blocked task reference."},
       "depends_on_ref" => %{"type" => "string", "description" => "Blocking task reference."}
     }},
    {"remove_task_dependency", "Request removing a dependency between two tasks.",
     ~w(task_ref depends_on_ref),
     %{
       "task_ref" => %{"type" => "string", "description" => "Blocked task reference."},
       "depends_on_ref" => %{"type" => "string", "description" => "Blocking task reference."}
     }},
    {"move_task_to_workflow_step", "Request moving a task to a workflow step.",
     ~w(task_ref workflow_ref step_ref),
     %{
       "task_ref" => %{
         "type" => "string",
         "description" => "Task UUID or accepted short reference."
       },
       "workflow_ref" => %{"type" => "string", "description" => "Target workflow reference."},
       "step_ref" => %{"type" => "string", "description" => "Target workflow step reference."}
     }},
    {"tracker_task_write", "Request creating or editing tracker tasks.", ~w(operation title),
     %{
       "operation" => %{
         "type" => "string",
         "enum" => ["create"],
         "description" => "Tracker task write operation to perform."
       },
       "title" => %{"type" => "string", "description" => "Task title."},
       "description" => %{"type" => "string", "description" => "Task description."},
       "level" => %{"type" => "string", "description" => "Task level."},
       "priority" => %{"type" => "string", "description" => "Task priority."},
       "tags" => %{
         "type" => "array",
         "items" => %{"type" => "string"},
         "description" => "Task tags."
       },
       "parent_ref" => %{"type" => "string", "description" => "Parent task reference."},
       "depends_on_refs" => %{
         "type" => "array",
         "items" => %{"type" => "string"},
         "description" => "Task dependency references."
       },
       "workflow_ref" => %{"type" => "string", "description" => "Workflow reference."}
     }}
  ]

  @tool_names Enum.map(@tools, fn {name, _description, _required, _properties} -> name end)
  @required_by_name Map.new(@tools, fn {name, _description, required, _properties} ->
                      {name, required}
                    end)

  @spec all() :: [map()]
  def all do
    Enum.map(@tools, fn {name, description, required, properties} ->
      %{
        "type" => "function",
        "function" => %{
          "name" => name,
          "description" => description,
          "parameters" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => required,
            "properties" => properties
          }
        }
      }
    end)
  end

  @spec known_function_name?(String.t()) :: boolean()
  def known_function_name?(name) when is_binary(name), do: name in @tool_names
  def known_function_name?(_), do: false

  @spec required_keys(String.t()) :: {:ok, [String.t()]} | :error
  def required_keys(name) when is_binary(name) do
    case Map.fetch(@required_by_name, name) do
      {:ok, keys} -> {:ok, keys}
      :error -> :error
    end
  end

  def required_keys(_), do: :error

  @spec server_owned_argument_keys() :: [String.t()]
  def server_owned_argument_keys, do: @server_owned_argument_keys

  @spec sanitize_arguments(map()) :: map()
  def sanitize_arguments(arguments) when is_map(arguments),
    do: Map.drop(arguments, @server_owned_argument_keys)

  def sanitize_arguments(_), do: %{}

  @spec provider_tool_call(String.t(), map(), String.t()) :: map()
  def provider_tool_call(name, arguments, id) when is_binary(name) and is_binary(id) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(sanitize_arguments(arguments))
      }
    }
  end
end
