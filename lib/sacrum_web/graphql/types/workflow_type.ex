defmodule SacrumWeb.Graphql.Types.WorkflowType do
  @moduledoc """
  GraphQL type definition for Workflow resource.
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts

  object :workflow do
    field :id, :id
    field :name, :string
    field :description, :string
    field :initial_step_id, :id
    field :metadata, :json
    field :auto_advance, :boolean
    field :display_order, :integer
    field :is_default, :boolean
    field :track, :string
    field :kanban_column, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Sacrum.Accounts.Projects))
    end

    field :workflow_steps, list_of(:workflow_step) do
      resolve(dataloader(Sacrum.Accounts.WorkflowSteps))
    end

    field :transitions, list_of(:workflow_transition) do
      resolve(dataloader(Sacrum.Accounts.WorkflowTransitions))
    end

    field :on_done_workflow_id, :id

    field :on_done_workflow, :workflow do
      resolve(dataloader(Sacrum.Accounts.Workflows))
    end

    field :on_reject_workflow_id, :id

    field :on_reject_workflow, :workflow do
      resolve(dataloader(Sacrum.Accounts.Workflows))
    end
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
      arg(:track, :string)
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
      arg(:initial_step_id, :uuid4)
      arg(:on_done_workflow_id, :uuid4)
      arg(:on_reject_workflow_id, :uuid4)
      arg(:track, :string)
      arg(:kanban_column, :string)

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        with {:ok, workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: id]) do
          attrs = Map.drop(args, [:id])
          Accounts.Workflows.update(workflow, attrs)
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
end
