defmodule Sacrum.Repo.Schemas.Task do
  use Ecto.Schema
  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.TaskDependency
  alias Sacrum.Repo.Schemas.TaskSection
  alias Sacrum.Repo.Schemas.TaskWorkspace

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_levels ["epic", "ticket", "task"]
  @valid_priorities ["low", "medium", "high", "critical"]
  @parent_scope_constraint "tasks_parent_scope_fkey"
  @parent_scope_error "parent task must belong to the same project and user"

  @create_fields [
    :title,
    :description,
    :level,
    :priority,
    :tags,
    :parent_id,
    :workflow_id,
    :current_step_id
  ]
  @update_fields [
    :title,
    :description,
    :level,
    :priority,
    :tags,
    :parent_id,
    :started_at,
    :completed_at,
    :archived
  ]

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :level, :string, default: "task"
    field :priority, :string, default: "medium"
    field :tags, {:array, :string}, default: []
    field :rejection_reason, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    # Kept as a virtual compatibility field.  It is populated from
    # `workspace.worktree_path` after reads and is translated back into the
    # embed by the changesets; it is never persisted independently.
    field :worktree, :string, virtual: true
    field :workspace_daemon_id, :binary_id, read_after_writes: true
    embeds_one :workspace, TaskWorkspace, on_replace: :delete
    field :archived, :boolean, default: false
    field :status, :string, default: "ready"

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :current_step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :sections, Sacrum.Repo.Schemas.TaskSection, on_replace: :delete

    has_many :code_refs, Sacrum.Repo.Schemas.CodeRef,
      preload_order: [asc: :order_index, asc: :inserted_at]

    has_many :task_runs, Sacrum.Repo.Schemas.TaskRun
    has_many :step_executions, Sacrum.Repo.Schemas.StepExecution

    # Dependencies (blockers — tasks this task depends on)
    has_many :task_dependencies, TaskDependency, foreign_key: :task_id
    has_many :blockers, through: [:task_dependencies, :depends_on]

    # Dependencies (dependents — tasks that depend on this one)
    has_many :task_dependents, TaskDependency, foreign_key: :depends_on_id
    has_many :dependents, through: [:task_dependents, :task]

    # Hierarchy (parent)
    belongs_to :parent, Sacrum.Repo.Schemas.Task

    # Hierarchy (children)
    has_many :children, Sacrum.Repo.Schemas.Task, foreign_key: :parent_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(task, attrs) do
    user_id = task.user_id
    project_id = task.project_id
    attrs = normalize_workspace_attrs(normalize_legacy_worktree(attrs, nil))

    task
    |> cast(attrs, @create_fields)
    |> validate_required([:title])
    |> validate_inclusion(:level, @valid_levels)
    |> validate_inclusion(:priority, @valid_priorities)
    |> cast_embed(:workspace, with: &TaskWorkspace.changeset/2)
    |> cast_assoc(:sections,
      with: fn section, section_attrs ->
        section
        |> TaskSection.changeset(section_attrs)
        |> Ecto.Changeset.put_change(:user_id, user_id)
        |> Ecto.Changeset.put_change(:project_id, project_id)
      end
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:parent_id,
      name: @parent_scope_constraint,
      message: @parent_scope_error
    )
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:current_step_id)
    |> foreign_key_constraint(:workspace_daemon_id, name: "tasks_workspace_daemon_id_fkey")
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(task, attrs) do
    user_id = task.user_id
    project_id = task.project_id
    attrs = normalize_workspace_attrs(normalize_legacy_worktree(attrs, task.workspace))

    task
    |> cast(attrs, @update_fields)
    |> validate_required([:title])
    |> validate_inclusion(:level, @valid_levels)
    |> validate_inclusion(:priority, @valid_priorities)
    |> cast_embed(:workspace, with: &TaskWorkspace.changeset/2)
    |> cast_assoc(:sections,
      with: fn section, section_attrs ->
        section
        |> TaskSection.changeset(section_attrs)
        |> Ecto.Changeset.put_change(:user_id, user_id)
        |> Ecto.Changeset.put_change(:project_id, project_id)
      end
    )
    |> foreign_key_constraint(:workspace_daemon_id, name: "tasks_workspace_daemon_id_fkey")
    |> foreign_key_constraint(:parent_id,
      name: @parent_scope_constraint,
      message: @parent_scope_error
    )
  end

  @spec assign_workflow_changeset(t(), Ecto.UUID.t() | nil, Ecto.UUID.t() | nil) ::
          Ecto.Changeset.t()
  def assign_workflow_changeset(task, workflow_id, current_step_id) do
    task
    |> change(%{workflow_id: workflow_id, current_step_id: current_step_id})
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:current_step_id)
  end

  @doc "Returns the compatibility worktree value from the durable workspace."
  @spec legacy_worktree(t()) :: String.t() | nil
  def legacy_worktree(%__MODULE__{workspace: workspace, worktree: worktree}) do
    case workspace_worktree(workspace) do
      nil -> worktree
      path -> path
    end
  end

  def legacy_worktree(%{workspace: workspace, worktree: worktree}) do
    case workspace_worktree(workspace) do
      nil -> worktree
      path -> path
    end
  end

  def legacy_worktree(%{worktree: worktree}), do: worktree
  def legacy_worktree(_task), do: nil

  @doc "Returns a task with its virtual legacy worktree compatibility field populated."
  @spec with_legacy_worktree(t()) :: t()
  def with_legacy_worktree(%__MODULE__{} = task) do
    %{task | worktree: legacy_worktree(task)}
  end

  @doc "Returns the durable worktree path for a task or task-like row."
  @spec workspace_worktree(t() | map() | nil) :: String.t() | nil
  def workspace_worktree(nil), do: nil

  def workspace_worktree(%__MODULE__{} = task) do
    workspace_worktree(task.workspace) || task.worktree
  end

  def workspace_worktree(%{worktree: worktree}), do: worktree
  def workspace_worktree(%TaskWorkspace{worktree_path: path}), do: path
  def workspace_worktree(%{worktree_path: path}), do: path
  def workspace_worktree(_), do: nil

  @doc "Returns the authorized API/realtime shape of a task workspace."
  @spec workspace_payload(t() | map() | nil) :: map() | nil
  def workspace_payload(nil), do: nil

  def workspace_payload(task_or_workspace) do
    workspace =
      case task_or_workspace do
        %__MODULE__{workspace: workspace} -> workspace
        workspace -> workspace
      end

    case TaskWorkspace.normalize(workspace) do
      nil ->
        nil

      :invalid ->
        nil

      workspace ->
        %{daemon_id: workspace_daemon(workspace), worktree_path: workspace_worktree(workspace)}
    end
  end

  @doc "Returns the durable daemon id for a task or task-like row."
  @spec workspace_daemon(t() | map() | nil) :: Ecto.UUID.t() | nil
  def workspace_daemon(nil), do: nil
  def workspace_daemon(%__MODULE__{workspace: workspace}), do: workspace_daemon(workspace)
  def workspace_daemon(%TaskWorkspace{daemon_id: daemon_id}), do: daemon_id
  def workspace_daemon(%{daemon_id: daemon_id}), do: daemon_id
  def workspace_daemon(_), do: nil

  defp normalize_legacy_worktree(attrs, current_workspace) when is_map(attrs) do
    case legacy_worktree_attr(attrs) do
      :missing ->
        attrs

      path ->
        workspace = Map.get(attrs, :workspace)
        workspace = workspace || current_workspace || %{}
        workspace = workspace |> TaskWorkspace.from_attrs() |> Map.put(:worktree_path, path)

        attrs
        |> Map.delete(:worktree)
        |> Map.put(:workspace, workspace)
    end
  end

  defp normalize_workspace_attrs(attrs) when is_map(attrs) do
    case workspace_attr(attrs) do
      :missing ->
        attrs

      workspace ->
        workspace = TaskWorkspace.normalize(workspace)
        workspace = if is_struct(workspace), do: Map.from_struct(workspace), else: workspace
        Map.put(attrs, :workspace, workspace)
    end
  end

  defp workspace_attr(attrs) do
    if Map.has_key?(attrs, :workspace), do: Map.fetch!(attrs, :workspace), else: :missing
  end

  defp legacy_worktree_attr(attrs) do
    if Map.has_key?(attrs, :worktree), do: Map.fetch!(attrs, :worktree), else: :missing
  end
end
