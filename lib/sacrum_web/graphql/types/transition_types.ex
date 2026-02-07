defmodule SacrumWeb.Graphql.Types.TransitionTypes do
  @moduledoc """
  GraphQL type definitions for Transition resources (WorkflowTransition and StepTransition).
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts

  object :workflow_transition do
    field :id, :id
    field :label, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :from_workflow_id, :id

    field :from_workflow, :workflow do
      resolve(dataloader(Accounts.Workflows))
    end

    field :to_workflow_id, :id

    field :to_workflow, :workflow do
      resolve(dataloader(Accounts.Workflows))
    end

    field :target_step_id, :id

    field :target_step, :workflow_step do
      resolve(dataloader(Accounts.WorkflowSteps))
    end

    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Accounts.Projects))
    end
  end

  object :step_transition do
    field :id, :id
    field :label, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :from_step_id, :id

    field :from_step, :workflow_step do
      resolve(dataloader(Accounts.WorkflowSteps))
    end

    field :to_step_id, :id

    field :to_step, :workflow_step do
      resolve(dataloader(Accounts.WorkflowSteps))
    end

    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Accounts.Projects))
    end
  end

  object :transition_mutations do
    field :create_workflow_transition, :workflow_transition do
      arg(:from_workflow_id, non_null(:uuid4))
      arg(:to_workflow_id, non_null(:uuid4))
      arg(:label, :string)
      arg(:target_step_id, :uuid4)

      resolve(fn args, %{context: %{current_user: user}} ->
        from_wf_id = Map.get(args, :from_workflow_id)

        with {:ok, wf} <- Accounts.Workflows.get_by(user.id, conditions: [id: from_wf_id]) do
          Accounts.WorkflowTransitions.insert(user.id, Map.put(args, :project_id, wf.project_id))
        end
      end)
    end

    field :delete_workflow_transition, :workflow_transition do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        with {:ok, transition} <-
               Accounts.WorkflowTransitions.get_by(user.id, conditions: [id: id]) do
          Accounts.WorkflowTransitions.delete(transition)
        end
      end)
    end

    field :create_step_transition, :step_transition do
      arg(:from_step_id, non_null(:uuid4))
      arg(:to_step_id, non_null(:uuid4))
      arg(:label, :string)

      resolve(fn args, %{context: %{current_user: user}} ->
        from_step_id = Map.get(args, :from_step_id)

        with {:ok, step} <- Accounts.WorkflowSteps.get_by(user.id, conditions: [id: from_step_id]) do
          Accounts.StepTransitions.insert(user.id, Map.put(args, :project_id, step.project_id))
        end
      end)
    end

    field :delete_step_transition, :step_transition do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        with {:ok, transition} <- Accounts.StepTransitions.get_by(user.id, conditions: [id: id]) do
          Accounts.StepTransitions.delete(transition)
        end
      end)
    end
  end
end
