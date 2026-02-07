defmodule SacrumWeb.Graphql.Types.WorkflowStepType do
  @moduledoc """
  GraphQL type definition for WorkflowStep resource.
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts

  object :workflow_step do
    field :id, :id
    field :name, :string
    field :goal, :string
    field :agents, list_of(:string)
    field :skills, list_of(:string)
    field :agent_config, :json
    field :is_final, :boolean
    field :step_order, :integer
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
      resolve(dataloader(Sacrum.Accounts.StepTransitions))
    end
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
  end

  object :workflow_step_mutations do
    field :create_workflow_step, :workflow_step do
      arg(:workflow_id, non_null(:uuid4))
      arg(:name, non_null(:string))
      arg(:goal, :string)
      arg(:agents, list_of(:string))
      arg(:skills, list_of(:string))
      arg(:agent_config, :json)
      arg(:is_final, :boolean)
      arg(:step_order, :integer)

      resolve(fn args, %{context: %{current_user: user}} ->
        workflow_id = Map.get(args, :workflow_id)

        with {:ok, workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: workflow_id]) do
          attrs = args
          Accounts.WorkflowSteps.insert(workflow, attrs)
        end
      end)
    end

    field :update_workflow_step, :workflow_step do
      arg(:id, non_null(:uuid4))
      arg(:name, :string)
      arg(:goal, :string)
      arg(:agents, list_of(:string))
      arg(:skills, list_of(:string))
      arg(:agent_config, :json)
      arg(:is_final, :boolean)
      arg(:step_order, :integer)

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        with {:ok, step} <- Accounts.WorkflowSteps.get_by(user.id, conditions: [id: id]) do
          attrs = Map.drop(args, [:id])
          Accounts.WorkflowSteps.update(step, attrs)
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
        with {:ok, step} <- Accounts.WorkflowSteps.get_by(user.id, conditions: [id: id]) do
          Accounts.WorkflowSteps.sync_transitions(step, transitions)
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
