defmodule Sacrum.WorkflowBundles.Manifest do
  @moduledoc """
  Boundary validation for the portable V1 workflow bundle manifest.

  The manifest is deliberately kept as JSON-shaped data at the transport
  boundary. This module validates its structural fields, normalizes them to
  atom-keyed internal values. RouteRefs resolves only the documented route
  target references; opaque JSON fields are never traversed or rewritten.
  """

  alias Sacrum.WorkflowBundles.RouteRefs

  @schema_version 1
  @max_bytes 1_048_576
  @max_depth 32
  @max_workflows 100
  @max_steps 1_000
  @max_edges 5_000

  @workflow_keys ~w(
    workflow_ref name description display_order is_default kanban_column factory_name metadata
    initial_step steps
  )
  @step_keys ~w(
    step_ref name goal prompt agents skills agent_config step_type step_order output_schema
    persistence_options route_config
  )
  @workflow_fields [
    {"description", :description, nil},
    {"display_order", :display_order, 0},
    {"is_default", :is_default, false},
    {"kanban_column", :kanban_column, nil},
    {"factory_name", :factory_name, nil},
    {"metadata", :metadata, nil}
  ]
  @step_fields [
    {"goal", :goal, nil},
    {"prompt", :prompt, nil},
    {"agents", :agents, []},
    {"skills", :skills, []},
    {"agent_config", :agent_config, nil},
    {"step_type", :step_type, "execute"},
    {"step_order", :step_order, 0},
    {"output_schema", :output_schema, nil},
    {"persistence_options", :persistence_options, nil},
    {"route_config", :route_config, nil}
  ]

  @type address :: %{workflow_ref: String.t(), step_ref: String.t()}
  @type workflow :: %{
          workflow_ref: String.t(),
          name: String.t(),
          description: String.t() | nil,
          display_order: integer(),
          is_default: boolean(),
          kanban_column: String.t() | nil,
          factory_name: String.t() | nil,
          metadata: map() | nil,
          initial_step: address() | nil,
          steps: [map()]
        }
  @type t :: %{
          schema_version: 1,
          workflows: [workflow()],
          step_edges: [map()],
          workflow_edges: [map()]
        }
  @type error :: %{path: String.t(), message: String.t()}

  @doc "Validates and normalizes a decoded V1 JSON manifest."
  @spec validate(term()) :: {:ok, t()} | {:error, error()}
  def validate(bundle) when is_map(bundle) do
    with {:ok, json} <- encode_json(bundle),
         :ok <- validate_size(json, bundle),
         :ok <-
           validate_keys(
             bundle,
             ["schema_version"],
             ["workflows", "step_edges", "workflow_edges"],
             "$"
           ),
         :ok <- validate_schema_version(Map.fetch(bundle, "schema_version")),
         {:ok, workflows} <- validate_workflows(Map.get(bundle, "workflows", [])),
         {:ok, step_edges} <- validate_step_edges(Map.get(bundle, "step_edges", []), workflows),
         {:ok, workflow_edges} <-
           validate_workflow_edges(Map.get(bundle, "workflow_edges", []), workflows),
         :ok <- validate_graph_constraints(workflows, step_edges) do
      {:ok,
       %{
         schema_version: @schema_version,
         workflows: workflows,
         step_edges: step_edges,
         workflow_edges: workflow_edges
       }}
    end
  end

  def validate(_bundle), do: {:error, error("$", "must be a JSON object")}

  @doc "Remaps all route configurations in a validated bundle."
  @spec remap_routes(t(), map(), map()) :: {:ok, t()} | {:error, error()}
  def remap_routes(bundle, workflow_ids, step_ids),
    do: RouteRefs.remap(bundle, workflow_ids, step_ids)

  defp encode_json(bundle) do
    case Jason.encode(bundle) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, error("$", "must contain only JSON values")}
    end
  end

  defp validate_size(json, bundle) do
    with :ok <- validate_byte_size(json),
         :ok <- validate_depth(json_depth(bundle)) do
      validate_collection_limits(bundle)
    end
  end

  defp validate_byte_size(json) when byte_size(json) <= @max_bytes, do: :ok

  defp validate_byte_size(_json),
    do: {:error, error("$", "exceeds the maximum bundle size of #{@max_bytes} bytes")}

  defp validate_depth(depth) when depth <= @max_depth, do: :ok

  defp validate_depth(_depth),
    do: {:error, error("$", "exceeds the maximum JSON depth of #{@max_depth}")}

  defp validate_collection_limits(bundle) do
    workflows = Map.get(bundle, "workflows", [])
    step_edges = Map.get(bundle, "step_edges", [])
    workflow_edges = Map.get(bundle, "workflow_edges", [])

    cond do
      is_list(workflows) and length(workflows) > @max_workflows ->
        {:error, error("workflows", "must contain at most #{@max_workflows} workflows")}

      is_list(workflows) and total_steps(workflows) > @max_steps ->
        {:error, error("workflows", "must contain at most #{@max_steps} steps")}

      is_list(step_edges) and is_list(workflow_edges) and
          length(step_edges) + length(workflow_edges) > @max_edges ->
        {:error, error("$", "must contain at most #{@max_edges} graph edges")}

      true ->
        :ok
    end
  end

  defp total_steps(workflows) do
    Enum.reduce(workflows, 0, fn workflow, count ->
      steps = if(is_map(workflow), do: Map.get(workflow, "steps", []), else: [])
      count + if(is_list(steps), do: length(steps), else: 0)
    end)
  end

  defp validate_schema_version({:ok, @schema_version}), do: :ok

  defp validate_schema_version({:ok, version}),
    do: {:error, error("schema_version", "must be #{@schema_version}, got #{inspect(version)}")}

  defp validate_schema_version(:error), do: {:error, error("schema_version", "is required")}

  defp validate_workflows(workflows) when is_list(workflows) do
    case map_unique(workflows, "workflows", :workflow_ref, "workflow", &normalize_workflow/2) do
      {:ok, workflows, _refs} -> {:ok, workflows}
      {:error, _reason} = error -> error
    end
  end

  defp validate_workflows(_workflows),
    do: {:error, error("workflows", "must be an array")}

  defp normalize_workflow(workflow, index) when is_map(workflow) do
    path = "workflows[#{index}]"

    with :ok <- validate_keys(workflow, ~w(workflow_ref name), @workflow_keys, path),
         {:ok, workflow_ref} <- required_text(workflow, "workflow_ref", path),
         {:ok, name} <- required_text(workflow, "name", path),
         {:ok, initial_step} <- optional_address(workflow, "initial_step", path),
         {:ok, steps} <- optional_list(workflow, "steps", path),
         {:ok, normalized_steps, step_refs} <- normalize_steps(steps, path),
         :ok <- validate_initial_step(initial_step, workflow_ref, step_refs, path) do
      {:ok,
       atom_fields(workflow, @workflow_fields, %{
         workflow_ref: workflow_ref,
         name: name,
         initial_step: initial_step,
         steps: normalized_steps
       })}
    end
  end

  defp normalize_workflow(_workflow, index),
    do: {:error, error("workflows[#{index}]", "must be an object")}

  defp normalize_steps(steps, path) do
    map_unique(steps, "#{path}.steps", :step_ref, "step", &normalize_step(&1, path, &2))
  end

  defp map_unique(items, path, ref_key, kind, normalize) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {item, index}, {:ok, acc, refs} ->
      with {:ok, normalized} <- normalize.(item, index),
           ref <- Map.fetch!(normalized, ref_key),
           :ok <- unique_ref(ref, refs, "#{path}[#{index}].#{ref_key}", kind) do
        {:cont, {:ok, [normalized | acc], MapSet.put(refs, ref)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items, refs} -> {:ok, Enum.reverse(items), refs}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_step(step, workflow_path, index) when is_map(step) do
    path = "#{workflow_path}.steps[#{index}]"

    with :ok <- validate_keys(step, ~w(step_ref name), @step_keys, path),
         {:ok, step_ref} <- required_text(step, "step_ref", path),
         {:ok, name} <- required_text(step, "name", path) do
      {:ok, atom_fields(step, @step_fields, %{step_ref: step_ref, name: name})}
    end
  end

  defp normalize_step(_step, workflow_path, index),
    do: {:error, error("#{workflow_path}.steps[#{index}]", "must be an object")}

  defp atom_fields(map, fields, defaults) do
    Enum.reduce(fields, defaults, fn {json_key, atom_key, default}, acc ->
      Map.put(acc, atom_key, Map.get(map, json_key, default))
    end)
  end

  defp validate_step_edges(edges, workflows) when is_list(edges) do
    addresses = step_addresses(workflows)

    validate_edges(
      edges,
      "step_edges",
      &normalize_step_edge/2,
      &validate_step_edge(&1, addresses, &2),
      "step"
    )
  end

  defp validate_step_edges(_edges, _workflows),
    do: {:error, error("step_edges", "must be an array")}

  defp normalize_step_edge(edge, path) when is_map(edge) do
    with :ok <- validate_keys(edge, ["from", "to"], ["label"], path),
         {:ok, from} <- required_address(edge, "from", path),
         {:ok, to} <- required_address(edge, "to", path) do
      {:ok, %{from: from, to: to, label: Map.get(edge, "label")}}
    end
  end

  defp normalize_step_edge(_edge, path), do: {:error, error(path, "must be an object")}

  defp validate_step_edge(edge, addresses, path) do
    with :ok <- validate_same_workflow(edge.from, edge.to, path),
         :ok <- validate_address(edge.from, addresses, "#{path}.from") do
      validate_address(edge.to, addresses, "#{path}.to")
    end
  end

  defp validate_workflow_edges(edges, workflows) when is_list(edges) do
    workflow_refs = MapSet.new(Enum.map(workflows, & &1.workflow_ref))
    addresses = step_addresses(workflows)

    validate_edges(
      edges,
      "workflow_edges",
      &normalize_workflow_edge/2,
      &validate_workflow_edge(&1, workflow_refs, addresses, &2),
      "workflow"
    )
  end

  defp validate_workflow_edges(_edges, _workflows),
    do: {:error, error("workflow_edges", "must be an array")}

  defp normalize_workflow_edge(edge, path) when is_map(edge) do
    with :ok <-
           validate_keys(
             edge,
             ["from_workflow_ref", "to_workflow_ref"],
             ["destination_step", "label"],
             path
           ),
         {:ok, from_workflow_ref} <- required_text(edge, "from_workflow_ref", path),
         {:ok, to_workflow_ref} <- required_text(edge, "to_workflow_ref", path),
         {:ok, destination_step} <- optional_address(edge, "destination_step", path) do
      {:ok,
       %{
         from_workflow_ref: from_workflow_ref,
         to_workflow_ref: to_workflow_ref,
         destination_step: destination_step,
         label: Map.get(edge, "label")
       }}
    end
  end

  defp normalize_workflow_edge(_edge, path),
    do: {:error, error(path, "must be an object")}

  defp validate_workflow_edge(edge, workflow_refs, addresses, path) do
    with :ok <-
           validate_ref(
             edge.from_workflow_ref,
             workflow_refs,
             "#{path}.from_workflow_ref"
           ),
         :ok <- validate_ref(edge.to_workflow_ref, workflow_refs, "#{path}.to_workflow_ref") do
      validate_destination_step(edge, addresses, path)
    end
  end

  defp validate_edges(edges, path, normalize, validate, kind) do
    edges
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {edge, index}, {:ok, acc, seen} ->
      item_path = "#{path}[#{index}]"

      with {:ok, normalized} <- normalize.(edge, item_path),
           :ok <- validate.(normalized, item_path),
           key = edge_key(normalized),
           :ok <- unique_edge(key, seen, item_path, kind) do
        {:cont, {:ok, [normalized | acc], MapSet.put(seen, key)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_result()
  end

  defp validate_graph_constraints(workflows, step_edges) do
    outgoing =
      Enum.group_by(step_edges, & &1.from, & &1.to)

    Enum.reduce_while(Enum.with_index(workflows), :ok, fn {workflow, workflow_index}, :ok ->
      result = validate_workflow_graph_constraints(workflow, workflow_index, outgoing)

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_workflow_graph_constraints(workflow, workflow_index, outgoing) do
    Enum.reduce_while(Enum.with_index(workflow.steps), :ok, fn {step, step_index}, :ok ->
      count =
        outgoing
        |> Map.get(%{workflow_ref: workflow.workflow_ref, step_ref: step.step_ref}, [])
        |> length()

      case {step.step_type, count} do
        {"finish", 0} ->
          {:cont, :ok}

        {"finish", _count} ->
          {:halt,
           {:error,
            error(
              step_path(workflow_index, step_index),
              "finish steps cannot have outgoing step edges"
            )}}

        {"stop", 1} ->
          {:cont, :ok}

        {"stop", _count} ->
          {:halt,
           {:error,
            error(
              step_path(workflow_index, step_index),
              "stop steps require exactly one outgoing step edge"
            )}}

        _step ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_initial_step(nil, _workflow_ref, _step_refs, _path), do: :ok

  defp validate_initial_step(initial_step, workflow_ref, step_refs, path) do
    cond do
      initial_step.workflow_ref != workflow_ref ->
        {:error, error("#{path}.initial_step.workflow_ref", "must belong to this workflow")}

      not MapSet.member?(step_refs, initial_step.step_ref) ->
        {:error, error("#{path}.initial_step.step_ref", "is not a known step ref")}

      true ->
        :ok
    end
  end

  defp validate_destination_step(%{destination_step: nil}, _addresses, _path), do: :ok

  defp validate_destination_step(edge, addresses, path) do
    cond do
      edge.destination_step.workflow_ref != edge.to_workflow_ref ->
        {:error,
         error(
           "#{path}.destination_step.workflow_ref",
           "must belong to to_workflow_ref"
         )}

      not MapSet.member?(addresses, edge.destination_step) ->
        {:error, error("#{path}.destination_step", "is not a known step ref")}

      true ->
        :ok
    end
  end

  defp validate_same_workflow(from, to, path) do
    if from.workflow_ref == to.workflow_ref,
      do: :ok,
      else: {:error, error(path, "step edges cannot cross workflows")}
  end

  defp validate_address(address, addresses, path),
    do: validate_member(address, addresses, path, "is not a known step ref")

  defp validate_ref(ref, refs, path),
    do: validate_member(ref, refs, path, "is not a known workflow ref")

  defp validate_member(value, members, path, message) do
    if MapSet.member?(members, value), do: :ok, else: {:error, error(path, message)}
  end

  defp step_addresses(workflows) do
    workflows
    |> Enum.flat_map(fn workflow ->
      Enum.map(workflow.steps, &%{workflow_ref: workflow.workflow_ref, step_ref: &1.step_ref})
    end)
    |> MapSet.new()
  end

  defp required_address(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} -> validate_address_shape(value, "#{path}.#{key}")
      :error -> {:error, error("#{path}.#{key}", "is required")}
    end
  end

  defp optional_address(map, key, path) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> validate_address_shape(value, "#{path}.#{key}")
    end
  end

  defp validate_address_shape(value, path) when is_map(value) do
    with :ok <- validate_keys(value, ["workflow_ref", "step_ref"], [], path),
         {:ok, workflow_ref} <- required_text(value, "workflow_ref", path),
         {:ok, step_ref} <- required_text(value, "step_ref", path) do
      {:ok, %{workflow_ref: workflow_ref, step_ref: step_ref}}
    end
  end

  defp validate_address_shape(_value, path), do: {:error, error(path, "must be an object")}

  defp required_text(map, key, path) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, error("#{path}.#{key}", "must be a non-empty string")}
      :error -> {:error, error("#{path}.#{key}", "is required")}
    end
  end

  defp optional_list(map, key, path) do
    case Map.fetch(map, key) do
      :error -> {:ok, []}
      {:ok, values} when is_list(values) -> {:ok, values}
      {:ok, _value} -> {:error, error("#{path}.#{key}", "must be an array")}
    end
  end

  defp validate_keys(map, required, optional, path) do
    keys = Map.keys(map)
    allowed = required ++ optional
    missing = required -- keys
    unknown = keys -- allowed

    cond do
      Enum.any?(keys, &(not is_binary(&1))) ->
        {:error, error(path, "must use string keys")}

      missing != [] ->
        {:error, error("#{path}.#{hd(missing)}", "is required")}

      unknown != [] ->
        {:error, error("#{path}.#{hd(unknown)}", "is not allowed")}

      true ->
        :ok
    end
  end

  defp unique_ref(ref, refs, path, kind) do
    if MapSet.member?(refs, ref) do
      {:error, error(path, "duplicate #{kind} ref #{inspect(ref)}")}
    else
      :ok
    end
  end

  defp unique_edge(edge, seen, path, kind) do
    if MapSet.member?(seen, edge) do
      {:error, error(path, "duplicate #{kind} edge (same endpoints)")}
    else
      :ok
    end
  end

  defp edge_key(%{from: from, to: to}),
    do: {from.workflow_ref, from.step_ref, to.workflow_ref, to.step_ref}

  defp edge_key(%{from_workflow_ref: from, to_workflow_ref: to}), do: {from, to}

  defp reverse_result({:ok, acc, _seen}), do: {:ok, Enum.reverse(acc)}
  defp reverse_result({:error, _reason} = error), do: error

  defp step_path(workflow_index, step_index),
    do: "workflows[#{workflow_index}].steps[#{step_index}]"

  defp json_depth(value) when is_map(value) do
    1 + max_nested_depth(Map.values(value))
  end

  defp json_depth(value) when is_list(value), do: 1 + max_nested_depth(value)
  defp json_depth(_value), do: 1

  defp max_nested_depth([]), do: 0
  defp max_nested_depth(values), do: Enum.max(Enum.map(values, &json_depth/1))

  defp error(path, message), do: %{path: path, message: message}
end
