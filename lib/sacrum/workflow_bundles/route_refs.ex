defmodule Sacrum.WorkflowBundles.RouteRefs do
  @moduledoc """
  Resolves portable route references after the importer has allocated IDs.

  Only `transition` values in route rules and the default decision are touched;
  the rest of the route configuration remains opaque JSON.
  """

  alias Sacrum.Routing.{RouteConfig, Traverse}

  @type error :: %{path: String.t(), message: String.t()}

  @spec remap(map(), map(), map()) :: {:ok, map()} | {:error, error()}
  def remap(bundle, workflow_ids, step_ids) do
    context = %{
      workflow_ids: workflow_ids,
      step_ids: step_ids,
      outgoing_steps:
        outgoing(bundle.step_edges, &{&1.from.workflow_ref, &1.from.step_ref}, & &1.to.step_ref),
      outgoing_workflows:
        outgoing(bundle.workflow_edges, & &1.from_workflow_ref, & &1.to_workflow_ref)
    }

    with {:ok, workflows} <-
           Traverse.map_while(bundle.workflows, &remap_workflow(&1, &2, context)) do
      {:ok, %{bundle | workflows: workflows}}
    end
  end

  defp outgoing(edges, key, value) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      Map.update(acc, key.(edge), MapSet.new([value.(edge)]), &MapSet.put(&1, value.(edge)))
    end)
  end

  defp remap_workflow(workflow, workflow_index, context) do
    with {:ok, steps} <-
           Traverse.map_while(workflow.steps, fn step, step_index ->
             remap_step(step, workflow, workflow_index, step_index, context)
           end) do
      {:ok, %{workflow | steps: steps}}
    end
  end

  defp remap_step(%{route_config: nil} = step, _workflow, _workflow_index, _step_index, _context),
    do: {:ok, step}

  defp remap_step(step, workflow, workflow_index, step_index, context) do
    case remap_config(step.route_config, workflow.workflow_ref, step.step_ref, context) do
      {:ok, route_config} ->
        {:ok, %{step | route_config: route_config}}

      {:error, reason} ->
        {:error,
         prefix_error(reason, "workflows[#{workflow_index}].steps[#{step_index}].route_config")}
    end
  end

  defp remap_config(config, workflow_ref, step_ref, context) when is_map(config) do
    with {:ok, config} <-
           remap_section(config, "rules", "$.rules", workflow_ref, step_ref, context),
         {:ok, config} <-
           remap_section(config, "default", "$.default", workflow_ref, step_ref, context) do
      validate_config(config)
    end
  end

  defp remap_config(_config, _workflow_ref, _step_ref, _context),
    do: {:error, error("$.route_config", "must be a JSON object")}

  defp remap_section(config, key, path, workflow_ref, step_ref, context) do
    with {:ok, value} <-
           remap_transitions(Map.fetch(config, key), path, workflow_ref, step_ref, context) do
      {:ok, maybe_put(config, key, value)}
    end
  end

  defp remap_transitions({:ok, entries}, path, workflow_ref, step_ref, context)
       when is_list(entries) do
    Traverse.map_while(entries, fn entry, index ->
      remap_transition(entry, "#{path}[#{index}]", workflow_ref, step_ref, context)
    end)
  end

  defp remap_transitions({:ok, entry}, path, workflow_ref, step_ref, context)
       when is_map(entry),
       do: remap_transition(entry, path, workflow_ref, step_ref, context)

  defp remap_transitions({:ok, value}, _path, _workflow_ref, _step_ref, _context),
    do: {:ok, value}

  defp remap_transitions(:error, _path, _workflow_ref, _step_ref, _context), do: {:ok, :unchanged}

  defp remap_transition(%{"transition" => target} = entry, path, workflow_ref, step_ref, context) do
    with {:ok, target} <-
           remap_target(target, workflow_ref, step_ref, context, "#{path}.transition") do
      {:ok, Map.put(entry, "transition", target)}
    end
  end

  defp remap_transition(entry, _path, _workflow_ref, _step_ref, _context), do: {:ok, entry}

  defp remap_target(%{"type" => type} = target, workflow_ref, step_ref, context, path)
       when type in ["intra_workflow", "inter_workflow"] do
    {ref_key, id_key, ids, lookup, edges, edge_message, unknown_message} =
      case type do
        "intra_workflow" ->
          {"step_ref", "step_id", context.step_ids, &{workflow_ref, &1},
           Map.get(context.outgoing_steps, {workflow_ref, step_ref}, MapSet.new()),
           "must be an outgoing step edge", "is not a known step ref"}

        "inter_workflow" ->
          {"workflow_ref", "workflow_id", context.workflow_ids, & &1,
           Map.get(context.outgoing_workflows, workflow_ref, MapSet.new()),
           "must be an outgoing workflow edge", "is not a known workflow ref"}
      end

    with {:ok, target_ref} <- required_ref(target, ref_key, path),
         {:ok, id} <- fetch_id(ids, lookup.(target_ref), "#{path}.#{ref_key}", unknown_message),
         :ok <- validate_outgoing(edges, target_ref, path, ref_key, edge_message) do
      {:ok, target |> Map.delete(ref_key) |> Map.put(id_key, id)}
    end
  end

  defp remap_target(target, _workflow_ref, _step_ref, _context, _path), do: {:ok, target}

  defp required_ref(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, ref} when is_binary(ref) and ref != "" -> {:ok, ref}
      {:ok, _value} -> {:error, error("#{path}.#{key}", "must be a non-empty string")}
      :error -> {:error, error("#{path}.#{key}", "is required")}
    end
  end

  defp fetch_id(ids, key, path, message) do
    case Map.fetch(ids, key) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, error(path, message)}
    end
  end

  defp validate_outgoing(edges, target, path, key, message) do
    if MapSet.member?(edges, target), do: :ok, else: {:error, error("#{path}.#{key}", message)}
  end

  defp validate_config(config) do
    case RouteConfig.decode(config) do
      {:ok, _program} -> {:ok, config}
      {:error, %{path: path, message: message}} -> {:error, error(path, message)}
    end
  end

  defp prefix_error(%{path: path, message: message}, prefix),
    do: error(join_path(prefix, path), message)

  defp join_path(prefix, "$"), do: prefix
  defp join_path(prefix, "$" <> suffix), do: prefix <> suffix
  defp maybe_put(map, _key, :unchanged), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp error(path, message), do: %{path: path, message: message}
end
