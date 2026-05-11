defmodule SacrumWeb.Graphql.Types.WorkflowType do
  @moduledoc """
  GraphQL type definition for Workflow resource.
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts
  alias SacrumWeb.Graphql.ShortIdErrors

  object :workflow do
    field :id, :id
    field :name, :string
    field :description, :string
    field :initial_step_id, :id
    field :metadata, :json
    field :auto_advance, :boolean
    field :display_order, :integer
    field :is_default, :boolean
    field :is_final, :boolean
    field :kanban_column, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Sacrum.Accounts.Projects))
    end

    field :workflow_steps, list_of(:workflow_step) do
      resolve(fn workflow, args, resolution ->
        case workflow do
          %{workflow_steps: steps} when is_list(steps) ->
            {:ok, steps}

          _ ->
            dataloader(Sacrum.Accounts.WorkflowSteps).(workflow, args, resolution)
        end
      end)
    end

    field :transitions, list_of(:workflow_transition) do
      resolve(dataloader(Sacrum.Accounts.WorkflowTransitions))
    end
  end

  object :pipeline_task_counts do
    field :epic, non_null(:integer)
    field :ticket, non_null(:integer)
    field :task, non_null(:integer)
  end

  object :pipeline_step_counts do
    field :epic, non_null(:integer)
    field :ticket, non_null(:integer)
    field :task, non_null(:integer)
    field :active, non_null(:integer)
  end

  object :workflow_queries do
    field :workflows, list_of(:workflow) do
      arg(:project_id, non_null(:uuid4))

      resolve(fn %{project_id: project_id}, %{context: %{current_user: user}} ->
        with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]) do
          workflows = Accounts.Workflows.list_by(user.id, conditions: [project_id: project_id])
          {:ok, workflows}
        end
      end)
    end

    field :workflow, :workflow do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        case Accounts.Workflows.get_by(user.id, conditions: [id: id]) do
          {:ok, workflow} -> {:ok, workflow}
          error -> error
        end
      end)
    end

    field :pipeline_summary, list_of(:workflow) do
      description("""
      All workflows in the project with steps, intra-workflow transitions, inter-workflow
      transitions, and per-step pipeline counts. Task buckets count non-archived
      epic/ticket/task rows. Active buckets count active TaskRun rows. Aggregates
      are batched across the full result set — no N+1 over steps.
      """)

      arg(:project_id, non_null(:uuid4))

      resolve(fn %{project_id: project_id}, %{context: %{current_user: user}} ->
        {:ok, workflows, aggregates} = Accounts.Workflows.pipeline_summary(user.id, project_id)
        {:ok, Enum.map(workflows, &attach_pipeline_aggregates(&1, aggregates))}
      end)
    end

    field :resolve_workflow_short_id, :workflow do
      arg(:project_id, non_null(:uuid4))
      arg(:prefix, non_null(:string))

      resolve(fn %{project_id: project_id, prefix: prefix}, %{context: %{current_user: user}} ->
        with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]) do
          user.id
          |> Accounts.Workflows.resolve_short_id(project_id, prefix)
          |> ShortIdErrors.format("workflow", prefix)
        end
      end)
    end
  end

  object :workflow_mutations do
    field :create_workflow, :workflow do
      arg(:project_id, non_null(:uuid4))
      arg(:name, non_null(:string))
      arg(:description, :string)
      arg(:metadata, :json)
      arg(:auto_advance, :boolean)
      arg(:display_order, :integer)
      arg(:is_default, :boolean)
      arg(:is_final, :boolean)
      arg(:kanban_column, :string)

      resolve(fn args, %{context: %{current_user: user}} ->
        project_id = Map.get(args, :project_id)

        with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]) do
          attrs = Map.put(args, :project_id, project_id)
          Accounts.Workflows.insert(user.id, project_id, attrs)
        end
      end)
    end

    field :update_workflow, :workflow do
      arg(:id, non_null(:uuid4))
      arg(:name, :string)
      arg(:description, :string)
      arg(:metadata, :json)
      arg(:auto_advance, :boolean)
      arg(:display_order, :integer)
      arg(:is_default, :boolean)
      arg(:is_final, :boolean)
      arg(:initial_step_id, :uuid4)
      arg(:kanban_column, :string)

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        with {:ok, workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: id]) do
          attrs = Map.drop(args, [:id])

          case Accounts.Workflows.update(workflow, attrs) do
            {:error, :is_final_with_outgoing_transitions} ->
              {:error,
               "cannot mark workflow as final: workflow has outgoing transitions. Remove the transitions first."}

            other ->
              other
          end
        end
      end)
    end

    field :delete_workflow, :workflow do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        with {:ok, workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: id]) do
          Accounts.Workflows.delete(workflow)
        end
      end)
    end

    field :sync_workflow_transitions, :workflow do
      arg(:id, non_null(:uuid4))
      arg(:transitions, non_null(list_of(non_null(:workflow_transition_input))))

      resolve(fn %{id: id, transitions: transitions}, %{context: %{current_user: user}} ->
        with {:ok, workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: id]),
             {:ok, _transitions} <- Accounts.Workflows.sync_transitions(workflow, transitions) do
          {:ok, workflow}
        end
      end)
    end
  end

  input_object :workflow_transition_input do
    field :label, :string
    field :from_workflow_id, :uuid4
    field :to_workflow_id, :uuid4
    field :target_step_id, :uuid4
  end

  @empty_pipeline_counts %{epic: 0, ticket: 0, task: 0, active: 0}

  defp attach_pipeline_aggregates(workflow, %{pipeline_counts_by_step_id: pipeline_counts}) do
    enriched_steps =
      Enum.map(workflow.workflow_steps || [], fn step ->
        counts = Map.merge(@empty_pipeline_counts, Map.get(pipeline_counts, step.id, %{}))

        Map.put(step, :__pipeline_aggregates, %{
          pipeline_counts: counts,
          task_counts: Map.take(counts, [:epic, :ticket, :task]),
          active_count: counts.active
        })
      end)

    Map.put(workflow, :workflow_steps, enriched_steps)
  end
end
