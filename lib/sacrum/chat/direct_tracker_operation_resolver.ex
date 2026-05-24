defmodule Sacrum.Chat.DirectTrackerOperationResolver do
  @moduledoc """
  Resolves model-requested direct tracker operations against server-owned chat context.

  This module does not perform tracker mutations. It only validates the directive
  envelope and resolves chat-visible target references to scoped Sacrum records.
  """

  alias Sacrum.Accounts
  alias Sacrum.Chat.DirectTrackerOperationTools
  alias Sacrum.Repo.Schemas.{ChatSession, Task, TaskSection, Workflow, WorkflowStep}
  alias Sacrum.Repo.{Tasks, TaskSections, Workflows, WorkflowSteps}

  @resolver_owned_fields ~w(
    chat_session_id
    chat_run_id
    active_object
    active_object_id
    active_object_type
    active_task_id
    object_id
    scope
  )
  @server_owned_fields Enum.uniq(
                         DirectTrackerOperationTools.server_owned_argument_keys() ++
                           @resolver_owned_fields
                       )

  @string_field_atoms %{
    "action" => :action,
    "depends_on_ref" => :depends_on_ref,
    "step_ref" => :step_ref,
    "task_ref" => :task_ref,
    "workflow_ref" => :workflow_ref
  }
  @target_key_atoms %{
    "depends_on" => :depends_on,
    "section" => :section,
    "task" => :task,
    "task_section" => :task_section,
    "workflow" => :workflow,
    "workflow_step" => :workflow_step
  }

  @type context :: %{
          required(:user_id) => String.t(),
          required(:project_id) => String.t(),
          required(:chat_session_id) => String.t(),
          optional(:chat_run_id) => String.t(),
          optional(:active_object) => map(),
          optional(:active_task_id) => String.t()
        }

  @spec resolve_directive(map(), context()) :: {:ok, map()} | {:error, term()}
  def resolve_directive(%{} = directive, %{} = context) do
    with :ok <- reject_model_scope_fields(directive),
         {:ok, action} <- fetch_string(directive, "action"),
         {:ok, args} <- directive_arguments(directive),
         {:ok, targets} <- resolve_directive_targets(action, args, context) do
      {:ok,
       %{
         action: action,
         arguments: args,
         targets: targets,
         scope: scope_from_context(context)
       }}
    end
  end

  def resolve_directive(_directive, _context), do: {:error, :invalid_direct_tracker_operation}

  @spec resolve_directives([map()], context()) :: {:ok, [map()]} | {:error, term()}
  def resolve_directives([_ | _] = directives, %{} = context),
    do: map_while_ok(directives, &resolve_directive(&1, context))

  def resolve_directives(_directives, _context), do: {:error, :invalid_direct_tracker_operation}

  @spec resolve_target_reference(map(), context()) :: {:ok, struct()} | {:error, term()}
  def resolve_target_reference(%{type: type, ref: ref}, context),
    do: resolve_target_reference(%{"type" => type, "ref" => ref}, context)

  def resolve_target_reference(%{"type" => type, "ref" => ref}, context)
      when type in [:task, "task"],
      do: resolve_task(context, ref)

  def resolve_target_reference(%{"type" => type, "ref" => ref}, context)
      when type in [:section, "section"],
      do: resolve_section(context, ref)

  def resolve_target_reference(%{"type" => type, "ref" => ref}, context)
      when type in [:workflow, "workflow"],
      do: resolve_workflow(context, ref)

  def resolve_target_reference(%{"type" => type, "ref" => ref}, context)
      when type in [:workflow_step, "workflow_step"],
      do: resolve_workflow_step(context, ref)

  def resolve_target_reference(_reference, _context), do: {:error, :invalid_target_reference}

  @spec context_from_session(ChatSession.t()) :: context()
  def context_from_session(%ChatSession{} = session) do
    metadata = session.public_metadata || %{}

    %{
      user_id: session.user_id,
      project_id: session.project_id,
      chat_session_id: session.id,
      chat_run_id: get_map_value(metadata, :chat_run_id),
      active_object: get_map_value(metadata, :active_object),
      active_task_id: get_map_value(metadata, :active_task_id)
    }
  end

  @spec serialize_resolution(map()) :: map()
  def serialize_resolution(%{
        action: action,
        arguments: arguments,
        targets: targets,
        scope: scope
      }) do
    %{
      "action" => action,
      "arguments" => arguments,
      "scope" => stringify_scope(scope),
      "targets" => Map.new(targets, fn {key, target} -> {to_string(key), target_ref(target)} end)
    }
  end

  @spec serialize_resolutions([map()]) :: [map()]
  def serialize_resolutions(resolved) when is_list(resolved),
    do: Enum.map(resolved, &serialize_resolution/1)

  @spec deserialize_resolution(map()) :: {:ok, map()} | {:error, term()}
  def deserialize_resolution(%{
        "action" => action,
        "arguments" => arguments,
        "scope" => scope,
        "targets" => targets
      })
      when is_binary(action) and is_map(arguments) and is_map(scope) and is_map(targets) do
    with {:ok, resolved_targets} <- deserialize_targets(targets, scope) do
      {:ok,
       %{
         action: action,
         arguments: arguments,
         scope: atomize_scope(scope),
         targets: resolved_targets
       }}
    end
  end

  def deserialize_resolution(_serialized), do: {:error, :invalid_direct_tracker_operation}

  @spec deserialize_resolutions([map()]) :: {:ok, [map()]} | {:error, term()}
  def deserialize_resolutions([_ | _] = serialized),
    do: map_while_ok(serialized, &deserialize_resolution/1)

  def deserialize_resolutions(_serialized), do: {:error, :invalid_direct_tracker_operation}

  @spec public_target(map()) :: map() | nil
  def public_target(%{"action" => action, "targets" => targets})
      when is_binary(action) and is_map(targets) do
    action
    |> public_target_keys()
    |> Enum.find_value(fn key ->
      case Map.get(targets, to_string(key)) do
        %{"type" => type, "id" => id} when is_binary(type) and is_binary(id) ->
          %{"type" => type, "id" => id}

        _other ->
          nil
      end
    end)
  end

  def public_target(_serialized), do: nil

  defp map_while_ok(items, fun) do
    result =
      Enum.reduce_while(items, {:ok, []}, fn
        %{} = item, {:ok, acc} ->
          case fun.(item) do
            {:ok, value} -> {:cont, {:ok, [value | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _other, _acc ->
          {:halt, {:error, :invalid_direct_tracker_operation}}
      end)

    case result do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp resolve_directive_targets(action, args, context)
       when action in [
              "show_task",
              "read_task_sections",
              "update_task_fields",
              "upsert_task_section"
            ] do
    with {:ok, task_ref} <- fetch_string(args, "task_ref"),
         {:ok, task} <- resolve_task(context, task_ref) do
      {:ok, %{task: task}}
    end
  end

  defp resolve_directive_targets("update_workflow_step", args, context) do
    with {:ok, workflow_ref} <- fetch_string(args, "workflow_ref"),
         {:ok, workflow} <- resolve_workflow(context, workflow_ref),
         {:ok, step} <- resolve_step_for_workflow_update(context, workflow, args),
         {:ok, task} <- resolve_active_task(context) do
      {:ok, %{workflow: workflow, workflow_step: step, task: task}}
    end
  end

  defp resolve_directive_targets("update_step_prompt", args, context) do
    with {:ok, _prompt} <- fetch_string(args, "prompt"),
         {:ok, step_ref} <- active_workflow_step_ref(context),
         {:ok, step} <- resolve_workflow_step(context, step_ref),
         {:ok, workflow} <- resolve_workflow(context, step.workflow_id),
         {:ok, task} <- resolve_active_task(context) do
      {:ok, %{workflow: workflow, workflow_step: step, task: task}}
    else
      :error -> {:error, {:missing_direct_tracker_field, "active_object"}}
      error -> error
    end
  end

  defp resolve_directive_targets("move_task_to_workflow_step", args, context) do
    with {:ok, task_ref} <- fetch_string(args, "task_ref"),
         {:ok, task} <- resolve_task(context, task_ref),
         {:ok, workflow_ref} <- fetch_string(args, "workflow_ref"),
         {:ok, workflow} <- resolve_workflow(context, workflow_ref),
         {:ok, step_ref} <- fetch_string(args, "step_ref"),
         {:ok, step} <- resolve_workflow_step_for_workflow(context, workflow, step_ref) do
      {:ok, %{task: task, workflow: workflow, workflow_step: step}}
    end
  end

  defp resolve_directive_targets(action, args, context)
       when action in ["add_task_dependency", "remove_task_dependency"] do
    with {:ok, task_ref} <- fetch_string(args, "task_ref"),
         {:ok, task} <- resolve_task(context, task_ref),
         {:ok, depends_on_ref} <- fetch_string(args, "depends_on_ref"),
         {:ok, depends_on} <- resolve_task(context, depends_on_ref) do
      {:ok, %{task: task, depends_on: depends_on}}
    end
  end

  defp resolve_directive_targets(_action, _args, _context),
    do: {:error, :unknown_direct_tracker_operation}

  defp deserialize_targets(targets, scope) do
    context = atomize_scope(scope)

    Enum.reduce_while(targets, {:ok, %{}}, fn {key, target}, {:ok, acc} ->
      with {:ok, target_key} <- target_key(key),
           {:ok, record} <- resolve_target_reference(target_reference(target), context) do
        {:cont, {:ok, Map.put(acc, target_key, record)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp target_key(key) do
    case Map.fetch(@target_key_atoms, to_string(key)) do
      {:ok, target_key} -> {:ok, target_key}
      :error -> {:error, :invalid_direct_tracker_operation}
    end
  end

  defp target_reference(%{"type" => type, "id" => id}), do: %{"type" => type, "ref" => id}
  defp target_reference(%{"type" => type, "ref" => ref}), do: %{"type" => type, "ref" => ref}
  defp target_reference(other), do: other

  defp public_target_keys(action) when action in ["update_workflow_step", "update_step_prompt"],
    do: [:workflow_step]

  defp public_target_keys("upsert_task_section"), do: [:task]
  defp public_target_keys(_action), do: [:task, :workflow_step, :workflow, :section]

  defp resolve_step_for_workflow_update(context, %Workflow{} = workflow, args) do
    case active_workflow_step_ref(context) do
      {:ok, step_ref} ->
        resolve_workflow_step_for_workflow(context, workflow, step_ref)

      :error ->
        resolve_model_supplied_workflow_step(context, workflow, args)
    end
  end

  defp resolve_model_supplied_workflow_step(context, %Workflow{} = workflow, args) do
    case fetch_string(args, "step_ref") do
      {:ok, step_ref} -> resolve_workflow_step_for_workflow(context, workflow, step_ref)
      error -> error
    end
  end

  defp active_workflow_step_ref(context) do
    with active when is_map(active) <- active_object(context),
         type when type in ["workflow_step", :workflow_step] <-
           Map.get(active, "type") || Map.get(active, :type),
         id when is_binary(id) <- Map.get(active, "id") || Map.get(active, :id) do
      {:ok, id}
    else
      _ -> :error
    end
  end

  defp resolve_workflow_step_for_workflow(context, %Workflow{} = workflow, step_ref) do
    case cast_ref(step_ref) do
      {:ok, _uuid} ->
        with {:ok, step} <- resolve_workflow_step(context, step_ref),
             :ok <- ensure_step_belongs_to_workflow(step, workflow, step_ref) do
          {:ok, step}
        end

      {:short_prefix, prefix} ->
        Accounts.WorkflowSteps.resolve_short_id(
          fetch_context!(context, :user_id),
          fetch_context!(context, :project_id),
          workflow.id,
          prefix
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_active_task(context) do
    case get_map_value(context, :active_task_id) do
      task_id when is_binary(task_id) and task_id != "" -> resolve_task(context, task_id)
      _ -> {:ok, nil}
    end
  end

  defp resolve_task(context, ref) do
    resolve_scoped_target(context, Accounts.Tasks, Tasks, Task, :task, ref)
  end

  defp resolve_section(context, ref) do
    resolve_scoped_target(context, Accounts.Sections, TaskSections, TaskSection, :section, ref)
  end

  defp resolve_workflow(context, ref) do
    resolve_scoped_target(context, Accounts.Workflows, Workflows, Workflow, :workflow, ref)
  end

  defp resolve_workflow_step(context, ref) do
    resolve_scoped_target(
      context,
      Accounts.WorkflowSteps,
      WorkflowSteps,
      WorkflowStep,
      :workflow_step,
      ref
    )
  end

  defp resolve_scoped_target(
         context,
         accounts_module,
         repo_module,
         schema_module,
         target_type,
         ref
       ) do
    user_id = fetch_context!(context, :user_id)
    project_id = fetch_context!(context, :project_id)

    case cast_ref(ref) do
      {:ok, uuid} ->
        case accounts_module.get_by(user_id, conditions: [id: uuid, project_id: project_id]) do
          {:ok, target} ->
            {:ok, target}

          {:error, :not_found} ->
            unauthorized_or_not_found(repo_module, schema_module, target_type, uuid)
        end

      {:short_prefix, prefix} ->
        resolve_short_target(accounts_module, target_type, user_id, project_id, prefix)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_short_target(Accounts.Tasks, :task, user_id, project_id, prefix),
    do: Accounts.Tasks.resolve_short_id(user_id, project_id, prefix)

  defp resolve_short_target(Accounts.Workflows, :workflow, user_id, project_id, prefix),
    do: Accounts.Workflows.resolve_short_id(user_id, project_id, prefix)

  defp resolve_short_target(_accounts_module, _target_type, _user_id, _project_id, _prefix),
    do: {:error, :not_found}

  defp unauthorized_or_not_found(repo_module, schema_module, target_type, uuid) do
    case repo_module.get_by(conditions: [id: uuid]) do
      {:ok, %^schema_module{id: id}} -> {:error, {:unauthorized_target, {target_type, id}}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp ensure_step_belongs_to_workflow(
         %WorkflowStep{workflow_id: workflow_id},
         %Workflow{id: workflow_id},
         _ref
       ),
       do: :ok

  defp ensure_step_belongs_to_workflow(%WorkflowStep{id: id}, _workflow, _ref),
    do: {:error, {:unauthorized_target, {:workflow_step, id}}}

  defp cast_ref(ref) when is_binary(ref) do
    case Ecto.UUID.cast(ref) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> cast_short_prefix(ref)
    end
  end

  defp cast_ref(_ref), do: {:error, :not_found}

  defp cast_short_prefix(ref) do
    if Regex.match?(~r/\A[0-9a-f]{1,8}\z/i, ref) do
      {:short_prefix, ref}
    else
      {:error, :not_found}
    end
  end

  defp directive_arguments(%{"arguments" => %{} = args}),
    do: reject_model_scope_fields(args, {:ok, args})

  defp directive_arguments(%{} = directive) do
    args = Map.drop(directive, ["action"])
    reject_model_scope_fields(args, {:ok, args})
  end

  defp reject_model_scope_fields(map), do: reject_model_scope_fields(map, :ok)

  defp reject_model_scope_fields(%{} = map, ok_result) do
    fields =
      map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.filter(&(&1 in @server_owned_fields))

    case fields do
      [] -> ok_result
      [_ | _] -> {:error, {:forbidden_model_scope_fields, Enum.sort(fields)}}
    end
  end

  defp fetch_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, Map.fetch!(@string_field_atoms, key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_direct_tracker_field, key}}
    end
  end

  defp active_object(context) do
    get_map_value(context, :active_object)
  end

  defp scope_from_context(context) do
    %{
      user_id: fetch_context!(context, :user_id),
      project_id: fetch_context!(context, :project_id),
      chat_session_id: fetch_context!(context, :chat_session_id),
      chat_run_id: get_map_value(context, :chat_run_id)
    }
  end

  defp target_ref(nil), do: nil

  defp target_ref(%{id: id} = record) do
    %{"type" => record_type(record), "id" => id}
  end

  defp record_type(%Task{}), do: "task"
  defp record_type(%TaskSection{}), do: "section"
  defp record_type(%Workflow{}), do: "workflow"
  defp record_type(%WorkflowStep{}), do: "workflow_step"

  defp stringify_scope(scope) do
    scope
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp atomize_scope(scope) do
    %{
      user_id: get_map_value(scope, :user_id),
      project_id: get_map_value(scope, :project_id),
      chat_session_id: get_map_value(scope, :chat_session_id),
      chat_run_id: get_map_value(scope, :chat_run_id)
    }
  end

  defp get_map_value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp fetch_context!(context, key) do
    Map.fetch!(context, key)
  rescue
    KeyError -> Map.fetch!(context, to_string(key))
  end
end
