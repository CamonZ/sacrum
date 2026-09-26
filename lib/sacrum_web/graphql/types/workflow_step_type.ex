defmodule SacrumWeb.Graphql.Types.WorkflowStepType do
  @moduledoc """
  GraphQL type definition for WorkflowStep resource.
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias SacrumWeb.Graphql.ChangesetErrors
  alias SacrumWeb.Graphql.ShortIdErrors

  @empty_task_counts %{epic: 0, ticket: 0, task: 0}
  @config_types %{
    Config.LlmInference => :llm_inference_step_config,
    Config.StructuredInference => :structured_inference_step_config,
    Config.Route => :route_step_config,
    Config.WaitChildren => :wait_children_step_config
  }
  @empty_pipeline_counts Map.put(@empty_task_counts, :active, 0)

  object :workflow_step do
    field :id, :id
    field :name, :string
    field :goal, :string
    field :step_order, :integer

    field :step_type, :string do
      resolve(fn step, _args, _resolution ->
        {:ok, WorkflowStep.step_type_wire_value(step.step_type)}
      end)
    end

    field :config, :workflow_step_config do
      description(
        "stepType-specific configuration; null for human_input, stop, and finish steps."
      )
    end

    field :persistence_options, :json
    field :verbose_daemon_logging, :boolean
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :workflow_id, :id

    field :workflow, :workflow do
      resolve(dataloader(Sacrum.Accounts.Workflows))
    end

    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Sacrum.Accounts.Projects))
    end

    field :transitions, list_of(:step_transition) do
      resolve(fn step, args, resolution ->
        case step do
          %{transitions: transitions} when is_list(transitions) ->
            {:ok, transitions}

          _ ->
            dataloader(Sacrum.Accounts.StepTransitions).(step, args, resolution)
        end
      end)
    end

    field :task_counts, :pipeline_task_counts do
      description("Compatibility task buckets for non-archived tasks at this step.")

      resolve(fn step, _args, _resolution ->
        counts =
          step
          |> Map.get(:__pipeline_aggregates, %{})
          |> Map.get(:task_counts, %{})

        {:ok, Map.merge(@empty_task_counts, counts)}
      end)
    end

    field :pipeline_counts, :pipeline_step_counts do
      description("Canonical per-step pipeline counts, including active TaskRun-backed work.")

      resolve(fn step, _args, _resolution ->
        counts =
          step
          |> Map.get(:__pipeline_aggregates, %{})
          |> Map.get(:pipeline_counts, %{})

        {:ok, Map.merge(@empty_pipeline_counts, counts)}
      end)
    end

    field :active_count, :integer do
      description("Convenience alias for pipelineCounts.active.")

      resolve(fn step, _args, _resolution ->
        aggregates = Map.get(step, :__pipeline_aggregates, %{})
        {:ok, Map.get(aggregates, :active_count, 0)}
      end)
    end

    field :running_count, :integer do
      description("Deprecated compatibility alias for activeCount.")
      deprecate("Use activeCount or pipelineCounts.active.")

      resolve(fn step, _args, _resolution ->
        aggregates = Map.get(step, :__pipeline_aggregates, %{})
        {:ok, Map.get(aggregates, :active_count, 0)}
      end)
    end
  end

  union :workflow_step_config do
    types([
      :llm_inference_step_config,
      :structured_inference_step_config,
      :route_step_config,
      :wait_children_step_config
    ])

    resolve_type(fn %module{}, _resolution -> Map.fetch!(@config_types, module) end)
  end

  object :llm_inference_step_config do
    field :version, non_null(:integer)
    field :prompt, :string
    field :output_schema, :json
    field :agents, list_of(:string)
    field :skills, list_of(:string)
    field :agent_config, :json
  end

  object :structured_inference_step_config do
    field :version, non_null(:integer)
    field :provider, :string
    field :model, :string
    field :state, :json
    field :questions, :json
  end

  object :route_step_config do
    field :version, non_null(:integer)
    field :route_config, :json
  end

  object :wait_children_step_config do
    field :version, non_null(:integer)
    field :output_schema, :json
  end

  object :workflow_step_queries do
    field :workflow_steps, list_of(:workflow_step) do
      arg(:workflow_id, non_null(:uuid4))

      resolve(fn %{workflow_id: workflow_id}, %{context: %{current_user: user}} ->
        with {:ok, _workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: workflow_id]) do
          steps = Accounts.WorkflowSteps.list_by(user.id, conditions: [workflow_id: workflow_id])
          {:ok, steps}
        end
      end)
    end

    field :workflow_step, :workflow_step do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        case Accounts.WorkflowSteps.get_by(user.id, conditions: [id: id]) do
          {:ok, step} -> {:ok, step}
          error -> error
        end
      end)
    end

    field :resolve_step_short_id, :workflow_step do
      arg(:project_id, non_null(:uuid4))
      arg(:workflow_id, non_null(:uuid4))
      arg(:prefix, non_null(:string))

      resolve(fn %{project_id: project_id, workflow_id: workflow_id, prefix: prefix},
                 %{context: %{current_user: user}} ->
        with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]),
             {:ok, _workflow} <-
               Accounts.Workflows.get_by(user.id,
                 conditions: [id: workflow_id, project_id: project_id]
               ) do
          user.id
          |> Accounts.WorkflowSteps.resolve_short_id(project_id, workflow_id, prefix)
          |> ShortIdErrors.format("step", prefix)
        end
      end)
    end
  end

  object :workflow_step_mutations do
    field :create_workflow_step, :workflow_step do
      arg(:workflow_id, non_null(:uuid4))
      arg(:name, non_null(:string))
      arg(:goal, :string)
      arg(:step_order, :integer)
      arg(:step_type, :string)
      arg(:config, :json)
      arg(:persistence_options, :json)

      resolve(fn args, %{context: %{current_user: user}} ->
        workflow_id = Map.get(args, :workflow_id)

        with {:ok, workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: workflow_id]) do
          case Accounts.WorkflowSteps.insert(workflow, args) do
            {:ok, step} -> {:ok, step}
            {:error, changeset} -> {:error, ChangesetErrors.format(changeset)}
          end
        end
      end)
    end

    field :update_workflow_step, :workflow_step do
      arg(:id, non_null(:uuid4))
      arg(:name, :string)
      arg(:goal, :string)
      arg(:step_order, :integer)
      arg(:step_type, :string)
      arg(:config, :json)
      arg(:persistence_options, :json)

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        with {:ok, step} <- Accounts.WorkflowSteps.get_by(user.id, conditions: [id: id]) do
          case Accounts.WorkflowSteps.update(step, Map.delete(args, :id)) do
            {:ok, step} -> {:ok, step}
            {:error, changeset} -> {:error, ChangesetErrors.format(changeset)}
          end
        end
      end)
    end

    field :delete_workflow_step, :workflow_step do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        with {:ok, step} <- Accounts.WorkflowSteps.get_by(user.id, conditions: [id: id]) do
          Accounts.WorkflowSteps.delete(step)
        end
      end)
    end

    field :sync_step_transitions, :workflow_step do
      arg(:id, non_null(:uuid4))
      arg(:transitions, non_null(list_of(non_null(:step_transition_input))))

      resolve(fn %{id: id, transitions: transitions}, %{context: %{current_user: user}} ->
        with {:ok, step} <- Accounts.WorkflowSteps.get_by(user.id, conditions: [id: id]),
             {:ok, _transitions} <- Accounts.WorkflowSteps.sync_transitions(step, transitions) do
          {:ok, step}
        end
      end)
    end
  end

  input_object :step_transition_input do
    field :label, :string
    field :from_step_id, :uuid4
    field :to_step_id, :uuid4
  end
end
