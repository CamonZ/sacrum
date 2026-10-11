defmodule Sacrum.Routing.RouteValidator do
  @moduledoc """
  Pure graph-aware validation for persisted route configurations.

  Runtime validation proves every route step's `route_config` against incoming
  predecessor contracts and persisted destination edges in an in-memory
  snapshot. Authoring validation also checks every supplied configuration but
  allows a route step with no configuration to be saved as a draft. Callers
  name the owner workflows whose routes to prove; the snapshot also holds
  support data (outgoing destinations) that those routes read.

  Session directives on the owners' step transitions are proved against the
  same snapshot, so a step edit that breaks one is rejected like one that
  breaks a route.

  Loading snapshots and revalidating inside write transactions belongs to
  `Sacrum.Repo.RouteValidation`; this module performs no I/O.
  """

  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.WorkflowStep.Config.WaitChildren

  alias Sacrum.Routing.{
    RouteConfig,
    RouteContext,
    RouteEvaluator,
    RouteOverlap,
    RoutePredecessors,
    SessionDirective
  }

  @type step_edge :: %{
          transition_id: binary(),
          from_step_id: binary(),
          to_step_id: binary(),
          session: map() | nil
        }

  @type workflow_edge :: %{
          target_step_id: binary() | nil,
          destination_workflow_id: binary(),
          initial_step_id: binary() | nil
        }

  @type snapshot :: %{
          steps: %{optional(binary()) => WorkflowStep.t()},
          step_edges: %{optional(binary()) => [step_edge()]},
          incoming_edges: %{optional(binary()) => [step_edge()]},
          workflow_edges: %{optional({binary(), binary()}) => workflow_edge()}
        }

  @type error :: %{
          optional(atom()) => term(),
          code: atom(),
          path: String.t(),
          message: String.t()
        }

  @doc """
  Validates route steps, route configuration ownership, and step transition
  and `wait_children` session directives in `owner_ids`.

  Destination workflows appear in the snapshot as support data so target
  checks can see their entry steps; their own routes are not subjects of
  this check.
  """
  @spec validate_snapshot(snapshot(), [binary()]) :: :ok | {:error, error()}
  def validate_snapshot(%{} = snapshot, owner_ids) when is_list(owner_ids) do
    validate_owner_routes(snapshot, owner_ids, false, false)
  end

  @doc """
  Validates route steps after an authoring write.

  An unconfigured route may remain a draft during any authoring write. For
  configured routes, predecessor or configured intra-workflow target edges
  may be added in separate writes when `allow_incomplete?` is true; those
  missing-connection errors are deferred until the graph is complete. Runtime
  loads continue to use `validate_snapshot/2` and reject unconfigured routes.
  """
  @spec validate_mutation_snapshot(snapshot(), [binary()], boolean()) ::
          :ok | {:error, error()}
  def validate_mutation_snapshot(%{} = snapshot, owner_ids, allow_incomplete?)
      when is_list(owner_ids) and is_boolean(allow_incomplete?) do
    validate_owner_routes(snapshot, owner_ids, true, allow_incomplete?)
  end

  defp validate_owner_routes(snapshot, owner_ids, authoring?, allow_incomplete?) do
    owners = MapSet.new(owner_ids)

    with :ok <- validate_route_steps(snapshot, owners, authoring?, allow_incomplete?),
         :ok <- validate_transition_sessions(snapshot, owners) do
      validate_wait_children_sessions(snapshot, owners)
    end
  end

  defp validate_route_steps(snapshot, owners, authoring?, allow_incomplete?) do
    snapshot.steps
    |> Enum.filter(fn {_id, step} ->
      route_requires_validation?(step, authoring?) and
        MapSet.member?(owners, step.workflow_id)
    end)
    |> Enum.reduce_while(:ok, fn {_id, step}, :ok ->
      case validate(step, snapshot) do
        :ok ->
          {:cont, :ok}

        {:error, reason} = error ->
          defer_incomplete_error(step, snapshot, reason, error, allow_incomplete?)
      end
    end)
  end

  defp route_requires_validation?(step, authoring?) do
    case {step.step_type, route_config(step)} do
      {:route, nil} -> not authoring?
      {:route, _route_config} -> true
      {_step_type, route_config} -> not is_nil(route_config)
    end
  end

  defp defer_incomplete_error(step, snapshot, reason, _error, true) do
    if incomplete_authoring_error?(step, snapshot, reason),
      do: {:cont, :ok},
      else: {:halt, {:error, reason}}
  end

  defp defer_incomplete_error(_step, _snapshot, _reason, error, _allow_incomplete?),
    do: {:halt, error}

  defp incomplete_authoring_error?(route_step, snapshot, %{
         code: :route_input_invalid,
         path: "$.predecessors"
       }) do
    predecessor_schemas(route_step, snapshot) == []
  end

  defp incomplete_authoring_error?(route_step, snapshot, %{
         code: :route_target_invalid,
         path: path
       }) do
    String.ends_with?(path, ".step_id") and missing_intra_workflow_targets?(route_step, snapshot)
  end

  defp incomplete_authoring_error?(_route_step, _snapshot, _reason), do: false

  defp missing_intra_workflow_targets?(route_step, snapshot) do
    case RouteConfig.decode(route_config(route_step)) do
      {:ok, program} ->
        configured_targets =
          (program.rules ++ List.wrap(program.default))
          |> Enum.map(& &1.transition)
          |> Enum.filter(&(&1.type == :intra_workflow))
          |> Enum.map(& &1.step_id)
          |> MapSet.new()

        targets_exist_in_workflow? =
          Enum.all?(configured_targets, &target_in_workflow?(&1, route_step, snapshot))

        connected_targets =
          snapshot.step_edges
          |> Map.get(route_step.id, [])
          |> MapSet.new(& &1.to_step_id)

        targets_exist_in_workflow? and not MapSet.subset?(configured_targets, connected_targets)

      {:error, _reason} ->
        false
    end
  end

  defp target_in_workflow?(target_id, route_step, snapshot) do
    case Map.get(snapshot.steps, target_id) do
      %{workflow_id: workflow_id} -> workflow_id == route_step.workflow_id
      nil -> false
    end
  end

  @doc """
  Validates one route step against the snapshot.

  A present configuration with no incoming predecessor edge is rejected:
  deterministic routing needs at least one declared result domain.
  """
  @spec validate(WorkflowStep.t(), snapshot()) :: :ok | {:error, error()}
  def validate(route_step, snapshot) do
    case {route_step.step_type, route_config(route_step)} do
      {:route, nil} ->
        reason = error(:route_config_required, "$.route_config", "is required for route steps")
        {:error, attach_route_step(reason, route_step)}

      {_step_type, nil} ->
        :ok

      {_step_type, route_config} ->
        validate_configured(route_step, route_config, snapshot)
    end
  end

  defp validate_configured(route_step, route_config, snapshot) do
    with :ok <- validate_route_step_type(route_step),
         {:ok, program} <- RouteConfig.decode(route_config),
         :ok <- validate_sessions(route_step, program, snapshot),
         {:ok, type_environment} <-
           RoutePredecessors.derive_type_environment(predecessor_schemas(route_step, snapshot)),
         :ok <- RoutePredecessors.validate(program, type_environment),
         domains = RoutePredecessors.closed_domains(program, type_environment),
         :ok <- validate_default_required(program, domains),
         :ok <- validate_finite_domain(program, domains),
         :ok <- RouteOverlap.validate(program, type_environment),
         :ok <- validate_targets(route_step, program, snapshot) do
      :ok
    else
      {:error, reason} -> {:error, attach_route_step(reason, route_step)}
    end
  end

  defp route_config(step), do: WorkflowStep.config_value(step, :route_config)

  defp validate_route_step_type(%{step_type: :route}), do: :ok

  defp validate_route_step_type(_route_step) do
    {:error, error(:route_config_invalid, "$.route_config", "is only supported for route steps")}
  end

  @doc """
  Returns the incoming predecessor schemas for a route step, keeping the
  edge identity so a contract error can identify the configuration to repair.
  """
  @spec predecessor_schemas(WorkflowStep.t(), snapshot()) :: [map()]
  def predecessor_schemas(route_step, snapshot) do
    snapshot.incoming_edges
    |> Map.get(route_step.id, [])
    |> Enum.map(fn edge ->
      source = Map.get(snapshot.steps, edge.from_step_id)

      %{
        transition_id: edge.transition_id,
        source_step_id: edge.from_step_id,
        destination_step_id: route_step.id,
        step_type: source && source.step_type,
        output_schema: source && WorkflowStep.output_schema(source)
      }
    end)
  end

  # Output rules the finite-domain analysis cannot enumerate could leave a
  # value unmatched at runtime, so they need an explicit default.
  defp validate_default_required(%{default: nil} = program, domains) do
    if Enum.all?(program.rules, &closed_rule?(&1, domains)) do
      :ok
    else
      {:error,
       error(
         :route_config_invalid,
         "$.default",
         "is required for rules on output values that are not required string enums"
       )}
    end
  end

  defp validate_default_required(_program, _domains), do: :ok

  #
  # Finite-domain analysis: one pass over every closed output value
  # combination x task level proves both overlap and coverage. Overlap is
  # reported in preference to a coverage gap.
  #

  defp validate_finite_domain(program, domains) do
    closed_rules = Enum.filter(program.rules, &closed_rule?(&1, domains))

    closed_rules
    |> Enum.flat_map(&RouteConfig.predicates(&1.when))
    |> Enum.map(& &1.ref)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> assignments(domains)
    |> Enum.flat_map(fn assignment ->
      for level <- RouteConfig.levels(), do: {assignment, level}
    end)
    |> Enum.reduce_while({:ok, nil, nil}, &analyze_combination(&1, &2, program, closed_rules))
    |> report_analysis(program)
  end

  # Prepending over the reversed references keeps each assignment in
  # reference order.
  defp assignments(references, domains) do
    references
    |> Enum.reverse()
    |> Enum.reduce([[]], fn reference, acc ->
      for assignment <- acc, value <- Map.fetch!(domains, reference) do
        [{reference, value} | assignment]
      end
    end)
  end

  defp analyze_combination({assignment, level}, {_, overlap, gap} = acc, program, closed_rules) do
    case matches_for(program, closed_rules, assignment, level) do
      {:ok, ids} when length(ids) > 1 and is_nil(overlap) ->
        {:cont, {:ok, %{rule_id: Enum.at(ids, 1), assignment: assignment, level: level}, gap}}

      {:ok, []} when is_nil(gap) and is_nil(program.default) ->
        {:cont, {:ok, overlap, %{assignment: assignment, level: level}}}

      {:ok, _ids} ->
        {:cont, acc}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp report_analysis({:ok, nil, nil}, _program), do: :ok

  defp report_analysis({:ok, nil, %{assignment: assignment, level: level}}, _program) do
    {:error,
     error(
       :route_config_uncovered,
       "$.rules",
       "does not cover #{describe_combination(assignment, level)}"
     )}
  end

  defp report_analysis(
         {:ok, %{rule_id: rule_id, assignment: assignment, level: level}, _gap},
         program
       ) do
    {:error,
     error(
       :route_config_ambiguous,
       "$.rules[#{rule_index(program, rule_id)}].when",
       "overlaps for #{describe_combination(assignment, level)}"
     )}
  end

  defp report_analysis({:error, _reason} = error, _program), do: error

  defp describe_combination(assignment, level) do
    Enum.map_join(assignment, fn {"previous_output." <> path, value} ->
      "#{path}=#{inspect(value)} and "
    end) <> "task.level=#{inspect(level)}"
  end

  defp matches_for(program, closed_rules, assignment, level) do
    with {:ok, context} <- finite_domain_context(assignment, level) do
      RouteEvaluator.matching_rule_ids(%{program | rules: closed_rules}, context)
    end
  end

  defp finite_domain_context(assignment, level) do
    previous_output =
      Enum.reduce(assignment, %{}, fn {"previous_output." <> path, value}, output ->
        put_in(output, path |> String.split(".") |> Enum.map(&Access.key(&1, %{})), value)
      end)

    RouteContext.build(previous_output, %{"level" => level, "tags" => []}, 1)
  end

  #
  # Target validation: reads only snapshot data.
  #

  defp validate_targets(route_step, program, snapshot) do
    case validate_rule_targets(route_step, program.rules, snapshot) do
      :ok -> validate_default_target(route_step, program.default, snapshot)
      {:error, _reason} = error -> error
    end
  end

  defp validate_rule_targets(route_step, rules, snapshot) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {%{transition: target}, index}, :ok ->
      case validate_target(route_step, target, "$.rules[#{index}].transition", snapshot) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_default_target(_route_step, nil, _snapshot), do: :ok

  defp validate_default_target(route_step, %{transition: target}, snapshot) do
    validate_target(route_step, target, "$.default.transition", snapshot)
  end

  defp validate_target(route_step, %{type: :intra_workflow, step_id: step_id}, path, snapshot) do
    outgoing_ids =
      snapshot.step_edges
      |> Map.get(route_step.id, [])
      |> MapSet.new(& &1.to_step_id)

    if MapSet.member?(outgoing_ids, step_id) do
      :ok
    else
      {:error,
       error(:route_target_invalid, "#{path}.step_id", "must be an outgoing step transition")}
    end
  end

  defp validate_target(
         route_step,
         %{type: :inter_workflow, workflow_id: workflow_id},
         path,
         snapshot
       ) do
    case Map.get(snapshot.workflow_edges, {route_step.workflow_id, workflow_id}) do
      nil ->
        {:error,
         error(
           :route_target_invalid,
           "#{path}.workflow_id",
           "must be an outgoing workflow transition"
         )}

      entry ->
        validate_workflow_entry(entry, workflow_id, path, snapshot)
    end
  end

  defp validate_workflow_entry(entry, workflow_id, path, snapshot) do
    step_id = entry.target_step_id || entry.initial_step_id

    cond do
      is_nil(step_id) ->
        validate_any_entry(snapshot, workflow_id, path)

      entry_step?(snapshot, step_id, workflow_id) ->
        :ok

      true ->
        {:error,
         error(
           :route_target_invalid,
           "#{path}.workflow_id",
           "must enter a configured step in the destination workflow"
         )}
    end
  end

  defp entry_step?(snapshot, step_id, workflow_id) do
    case Map.get(snapshot.steps, step_id) do
      %{workflow_id: ^workflow_id} -> true
      _ -> false
    end
  end

  defp validate_any_entry(snapshot, workflow_id, path) do
    if Enum.any?(snapshot.steps, fn {_id, step} -> step.workflow_id == workflow_id end) do
      :ok
    else
      {:error,
       error(
         :route_target_invalid,
         "#{path}.workflow_id",
         "must enter a configured step in the destination workflow"
       )}
    end
  end

  #
  # Session directives: on an intra_workflow decision the destination and the
  # referenced conversation step must be llm_inference steps of this workflow
  # on the same harness. An inter_workflow decision stays in the same TaskRun,
  # so it may resume or fork a conversation of this workflow; its destination
  # step is chosen at route time, so it must name the step and the harness is
  # checked at dispatch. They read only steps, so they are checked even while
  # predecessor and target edges may still be missing from an authoring draft.
  #

  defp validate_sessions(route_step, program, snapshot) do
    program.rules
    |> Enum.with_index(fn rule, index -> {rule, "$.rules[#{index}].session"} end)
    |> Enum.concat(if program.default, do: [{program.default, "$.default.session"}], else: [])
    |> Enum.reduce_while(:ok, fn {decision, path}, :ok ->
      case validate_session(route_step, decision, path, snapshot) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_session(_route_step, %{session: nil}, _path, _snapshot), do: :ok

  defp validate_session(
         route_step,
         %{session: session, transition: %{type: :inter_workflow}},
         path,
         snapshot
       ) do
    with {:error, %{path: path, message: message}} <-
           SessionDirective.validate_workflow_source(
             session,
             route_step.workflow_id,
             path,
             snapshot.steps
           ),
         do: {:error, error(:route_session_invalid, path, message)}
  end

  defp validate_session(
         route_step,
         %{session: session, transition: transition},
         path,
         snapshot
       ) do
    with {:ok, destination} <- session_destination(route_step, transition, path, snapshot) do
      validate_session_source(destination, session, path, snapshot)
    end
  end

  defp session_destination(route_step, %{type: :intra_workflow, step_id: step_id}, path, snapshot) do
    case Map.get(snapshot.steps, step_id) do
      %{step_type: :llm_inference, workflow_id: workflow_id} = step
      when workflow_id == route_step.workflow_id ->
        {:ok, step}

      _step ->
        session_destination(route_step, nil, path, snapshot)
    end
  end

  defp session_destination(_route_step, _transition, path, _snapshot) do
    {:error,
     error(
       :route_session_invalid,
       path,
       "requires an llm_inference destination step"
     )}
  end

  defp validate_session_source(destination, session, path, snapshot) do
    with {:error, %{path: path, message: message}} <-
           SessionDirective.validate_source(session, destination, path, snapshot.steps),
         do: {:error, error(:route_session_invalid, path, message)}
  end

  #
  # Step transition session directives: an unconditional edge into an
  # llm_inference step may carry the directive a route decision could. Edges
  # leaving a route step may not; the route's decisions own those. Like route
  # directives they read only steps, so drafts are checked too.
  #

  defp validate_transition_sessions(snapshot, owners) do
    snapshot.step_edges
    |> Enum.flat_map(fn {_from_step_id, edges} -> edges end)
    |> Enum.filter(&(not is_nil(&1.session)))
    |> Enum.map(&{Map.get(snapshot.steps, &1.from_step_id), &1})
    |> Enum.filter(fn {source, _edge} -> source && MapSet.member?(owners, source.workflow_id) end)
    |> Enum.sort_by(fn {_source, edge} -> edge.transition_id end)
    |> Enum.reduce_while(:ok, fn {source, edge}, :ok ->
      case validate_transition_session(source, edge, snapshot) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, attach_transition(reason, edge)}}
      end
    end)
  end

  defp validate_transition_session(%{step_type: :route}, _edge, _snapshot) do
    {:error,
     error(
       :step_transition_session_invalid,
       "$.session",
       "is not allowed on a transition leaving a route step; route decisions carry the session"
     )}
  end

  defp validate_transition_session(_source, edge, snapshot) do
    with {:ok, session} <- SessionDirective.decode(edge.session, "$.session"),
         {:ok, destination} <- transition_destination(edge, snapshot),
         :ok <-
           SessionDirective.validate_source(session, destination, "$.session", snapshot.steps) do
      :ok
    else
      {:error, %{path: path, message: message}} ->
        {:error, error(:step_transition_session_invalid, path, message)}
    end
  end

  defp transition_destination(edge, snapshot) do
    case Map.get(snapshot.steps, edge.to_step_id) do
      %{step_type: :llm_inference} = destination ->
        {:ok, destination}

      _step ->
        {:error, %{path: "$.session", message: "requires an llm_inference destination step"}}
    end
  end

  #
  # wait_children session directives: every child run forks a conversation
  # of the parent run, named by an llm_inference step of the parent's
  # workflow. The child's entry step and harness are checked at dispatch.
  #

  defp validate_wait_children_sessions(snapshot, owners) do
    snapshot.steps
    |> Map.values()
    |> Enum.filter(&wait_children_session?(&1, owners))
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while(:ok, fn step, :ok ->
      case validate_wait_children_session(step, snapshot) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, Map.put(reason, :step_id, step.id)}}
      end
    end)
  end

  defp wait_children_session?(
         %{step_type: :wait_children, config: %{session: %{}}} = step,
         owners
       ),
       do: MapSet.member?(owners, step.workflow_id)

  defp wait_children_session?(_step, _owners), do: false

  defp validate_wait_children_session(step, snapshot) do
    with {:ok, session} <- WaitChildren.decode_session(step.config.session),
         :ok <-
           SessionDirective.validate_workflow_source(
             session,
             step.workflow_id,
             "$.session",
             snapshot.steps
           ) do
      :ok
    else
      {:error, %{path: path, message: message}} ->
        {:error, error(:wait_children_session_invalid, path, message)}
    end
  end

  defp attach_transition(reason, edge) do
    Map.merge(reason, %{
      transition_id: edge.transition_id,
      from_step_id: edge.from_step_id,
      to_step_id: edge.to_step_id
    })
  end

  defp rule_index(program, rule_id), do: Enum.find_index(program.rules, &(&1.id == rule_id))

  defp attach_route_step(reason, route_step) do
    Map.merge(reason, %{route_step_id: route_step.id, workflow_id: route_step.workflow_id})
  end

  defp closed_rule?(%{when: expression}, domains) do
    expression
    |> RouteConfig.predicates()
    |> Enum.all?(fn %{ref: ref} -> ref == :task_level or Map.has_key?(domains, ref) end)
  end

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
