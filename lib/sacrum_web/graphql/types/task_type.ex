defmodule SacrumWeb.Graphql.Types.TaskType do
  @moduledoc """
  GraphQL type definition for Task resource.
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  require Logger

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.TaskRegistry
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.TaskWorkflows

  object :task do
    field :id, :id
    field :short_id, :string
    field :title, :string
    field :description, :string
    field :level, :string
    field :priority, :string
    field :tags, list_of(:string)
    field :needs_human_review, :boolean
    field :review_comment, :string
    field :rejection_reason, :string
    field :revision_feedback, :string
    field :started_at, :datetime
    field :completed_at, :datetime
    field :worktree, :string
    field :archived, :boolean
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Accounts.Projects))
    end

    field :workflow_id, :id

    field :workflow, :workflow do
      resolve(dataloader(Accounts.Workflows))
    end

    field :current_step_id, :id

    field :current_step, :workflow_step do
      resolve(dataloader(Accounts.WorkflowSteps))
    end

    field :parent_id, :id

    field :parent, :task do
      resolve(dataloader(Accounts.Tasks))
    end

    field :children, list_of(:task) do
      resolve(dataloader(Accounts.Tasks))
    end

    field :sections, list_of(:task_section) do
      resolve(dataloader(Accounts.Sections))
    end

    field :code_refs, list_of(:code_ref) do
      resolve(dataloader(Accounts.CodeRefs))
    end

    field :blockers, list_of(:task) do
      resolve(dataloader(Accounts.Tasks))
    end

    field :dependents, list_of(:task) do
      resolve(dataloader(Accounts.Tasks))
    end
  end

  object :task_queries do
    field :tasks, list_of(:task) do
      arg(:project_id, non_null(:uuid4))
      arg(:level, :string)
      arg(:priority, :string)
      arg(:parent_id, :uuid4)
      arg(:status, :string)
      arg(:tags, list_of(:string))
      arg(:search, :string)
      arg(:workflow_id, :uuid4)
      arg(:root_only, :boolean)
      arg(:blocked, :boolean)
      arg(:include_archived, :boolean, default_value: false)

      resolve(fn args, %{context: %{current_user: user}} ->
        project_id = Map.get(args, :project_id)
        include_archived = Map.get(args, :include_archived, false)

        with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]) do
          conditions =
            Enum.reject(
              [
                project_id: project_id,
                level: Map.get(args, :level),
                priority: Map.get(args, :priority),
                parent_id: Map.get(args, :parent_id),
                status: Map.get(args, :status),
                tags: Map.get(args, :tags),
                search: Map.get(args, :search),
                workflow_id: Map.get(args, :workflow_id),
                root_only: Map.get(args, :root_only),
                blocked: Map.get(args, :blocked),
                archived: if(include_archived, do: nil, else: false)
              ],
              fn {_k, v} -> is_nil(v) end
            )

          tasks = Accounts.Tasks.list_tasks(user.id, conditions: conditions)
          {:ok, tasks}
        end
      end)
    end

    field :task, :task do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        case Accounts.Tasks.find(user.id, id) do
          {:ok, task} -> {:ok, task}
          error -> error
        end
      end)
    end

    field :list_ready, list_of(:task) do
      arg(:project_id, non_null(:uuid4))

      resolve(fn %{project_id: project_id}, %{context: %{current_user: user}} ->
        with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]) do
          tasks = Accounts.Tasks.ready(user.id, project_id)
          {:ok, tasks}
        end
      end)
    end

    field :resolve_short_id, :task do
      arg(:project_id, non_null(:uuid4))
      arg(:prefix, non_null(:string))

      resolve(fn %{project_id: project_id, prefix: prefix}, %{context: %{current_user: user}} ->
        with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]) do
          Accounts.Tasks.resolve_short_id(user.id, project_id, prefix)
        end
      end)
    end

    field :find_path, list_of(:id) do
      arg(:from_id, non_null(:uuid4))
      arg(:to_id, non_null(:uuid4))

      resolve(fn %{from_id: from_id, to_id: to_id}, %{context: %{current_user: user}} ->
        with {:ok, from_task} <- Accounts.Tasks.find(user.id, from_id),
             {:ok, to_task} <- Accounts.Tasks.find(user.id, to_id) do
          TaskDependencies.find_path(from_task, to_task)
        end
      end)
    end
  end

  object :task_mutations do
    field :create_task, :task do
      arg(:project_id, non_null(:uuid4))
      arg(:title, non_null(:string))
      arg(:description, :string)
      arg(:level, :string)
      arg(:priority, :string)
      arg(:tags, list_of(:string))
      arg(:worktree, :string)
      arg(:parent_id, :uuid4)
      arg(:sections, list_of(:task_section_input))

      resolve(fn args, %{context: %{current_user: user}} ->
        project_id = Map.get(args, :project_id)

        with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]) do
          attrs = Map.drop(args, [:project_id])
          Accounts.Tasks.insert(user.id, project_id, attrs)
        end
      end)
    end

    field :update_task, :task do
      arg(:id, non_null(:uuid4))
      arg(:title, :string)
      arg(:description, :string)
      arg(:level, :string)
      arg(:priority, :string)
      arg(:tags, list_of(:string))
      arg(:needs_human_review, :boolean)
      arg(:review_comment, :string)
      arg(:rejection_reason, :string)
      arg(:revision_feedback, :string)
      arg(:started_at, :datetime)
      arg(:completed_at, :datetime)
      arg(:worktree, :string)
      arg(:archived, :boolean)
      arg(:parent_id, :uuid4)
      arg(:depends_on_ids, list_of(:uuid4))
      arg(:sections, list_of(:task_section_input))

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        with {:ok, task} <- Accounts.Tasks.find(user.id, id) do
          attrs = Map.drop(args, [:id])
          Accounts.Tasks.update(task, attrs)
        end
      end)
    end

    field :delete_task, :task do
      arg(:id, non_null(:uuid4))
      arg(:cascade, :boolean, default_value: true)

      resolve(fn %{id: id, cascade: cascade}, %{context: %{current_user: user}} ->
        with {:ok, task} <- Accounts.Tasks.find(user.id, id) do
          Accounts.Tasks.delete(task, cascade: cascade)
        end
      end)
    end

    field :create_task_dependency, :task do
      arg(:task_id, non_null(:uuid4))
      arg(:depends_on_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id, depends_on_id: dep_id}, %{context: %{current_user: user}} ->
        with {:ok, task} <- Accounts.Tasks.find(user.id, task_id),
             {:ok, dep_task} <- Accounts.Tasks.find(user.id, dep_id) do
          TaskDependencies.add_dependency(task, dep_task)
        end
      end)
    end

    field :delete_task_dependency, :task do
      arg(:task_id, non_null(:uuid4))
      arg(:depends_on_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id, depends_on_id: dep_id}, %{context: %{current_user: user}} ->
        with {:ok, task} <- Accounts.Tasks.find(user.id, task_id),
             {:ok, dep_task} <- Accounts.Tasks.find(user.id, dep_id) do
          TaskDependencies.remove_dependency(task, dep_task)
        end
      end)
    end

    field :assign_workflow, :task do
      arg(:task_id, non_null(:uuid4))
      arg(:workflow_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id, workflow_id: wf_id}, %{context: %{current_user: user}} ->
        with {:ok, task} <- Accounts.Tasks.find(user.id, task_id),
             {:ok, workflow} <- Accounts.Workflows.get_by(user.id, conditions: [id: wf_id]) do
          TaskWorkflows.assign_workflow(task, workflow)
        end
      end)
    end

    field :unassign_workflow, :task do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, resolution_context ->
        current_user = resolution_context.context.current_user
        api_token = resolution_context.context[:api_token]

        with :ok <-
               check_fsm_mutation_allowed(task_id, api_token, "unassignWorkflow", current_user),
             {:ok, task} <- Accounts.Tasks.find(current_user.id, task_id) do
          TaskWorkflows.unassign_workflow(task)
        end
      end)
    end

    field :move_to_step, :task do
      arg(:task_id, non_null(:uuid4))
      arg(:step_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id, step_id: step_id}, resolution_context ->
        current_user = resolution_context.context.current_user
        api_token = resolution_context.context[:api_token]

        with :ok <- check_fsm_mutation_allowed(task_id, api_token, "moveToStep", current_user),
             {:ok, task} <- Accounts.Tasks.find(current_user.id, task_id) do
          TaskWorkflows.move_to_step(task, step_id)
        end
      end)
    end

    @desc "Advance a task to a specific step, skipping transition validation"
    field :advance_to_step, :task do
      arg(:task_id, non_null(:uuid4))
      arg(:step_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id, step_id: step_id}, resolution_context ->
        current_user = resolution_context.context.current_user
        api_token = resolution_context.context[:api_token]

        with :ok <- check_fsm_mutation_allowed(task_id, api_token, "advanceToStep", current_user),
             {:ok, task} <- Accounts.Tasks.find(current_user.id, task_id) do
          TaskWorkflows.advance_to_step(task, step_id)
        end
      end)
    end

    field :start_step, :task do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, %{context: %{current_user: user}} ->
        with {:ok, task} <- Accounts.Tasks.find(user.id, task_id) do
          TaskWorkflows.start_current_step(task)
        end
      end)
    end

    field :complete_step, :task do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, %{context: %{current_user: user}} ->
        with {:ok, task} <- Accounts.Tasks.find(user.id, task_id) do
          TaskWorkflows.complete_current_step(task)
        end
      end)
    end

    field :reject_step, :task do
      arg(:task_id, non_null(:uuid4))
      arg(:target_step_id, non_null(:uuid4))
      arg(:feedback, :string)

      resolve(fn args, %{context: %{current_user: user}} ->
        with {:ok, task} <- Accounts.Tasks.find(user.id, args.task_id) do
          TaskWorkflows.reject_current_step(
            task,
            args.target_step_id,
            Map.get(args, :feedback)
          )
        end
      end)
    end
  end

  input_object :task_section_input do
    field :id, :uuid4
    field :section_type, non_null(:string)
    field :content, non_null(:string)
    field :section_order, :integer
    field :done, :boolean
    field :done_at, :datetime
  end

  defp check_fsm_mutation_allowed(task_id, api_token, mutation_name, user) do
    has_active_orchestrator = Registry.lookup(TaskRegistry, task_id) != []
    is_daemon_token = daemon_scoped_token?(api_token)

    if has_active_orchestrator or is_daemon_token do
      caller_identity = get_caller_identity(api_token, user)

      Logger.warning(
        "[GraphQL.TaskType] FSM mutation rejected: task_id=#{task_id} mutation=#{mutation_name} has_active_orchestrator=#{has_active_orchestrator} is_daemon_token=#{is_daemon_token} caller=#{caller_identity}"
      )

      {:error,
       message: "Cannot #{mutation_name} for task with active orchestrator or daemon-scoped token"}
    else
      :ok
    end
  end

  defp daemon_scoped_token?(api_token) when is_map(api_token) do
    scopes = Map.get(api_token, :scopes, [])
    "daemon" in scopes
  end

  defp daemon_scoped_token?(_), do: false

  defp get_caller_identity(api_token, user) when is_map(api_token) do
    token_name = Map.get(api_token, :name, "unknown")
    "#{user.email} via token:#{token_name}"
  end

  defp get_caller_identity(_, user) do
    user.email
  end
end
