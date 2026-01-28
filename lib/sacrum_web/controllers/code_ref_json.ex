defmodule SacrumWeb.CodeRefJSON do
  alias Sacrum.Repo.Schemas.CodeRef

  def index(%{code_refs: code_refs}) do
    %{data: for(ref <- code_refs, do: data(ref))}
  end

  def show(%{code_ref: code_ref}) do
    %{data: data(code_ref)}
  end

  defp data(%CodeRef{} = ref) do
    %{
      id: ref.id,
      task_id: ref.task_id,
      section_id: ref.section_id,
      path: ref.path,
      line_start: ref.line_start,
      line_end: ref.line_end,
      name: ref.name,
      description: ref.description,
      inserted_at: ref.inserted_at,
      updated_at: ref.updated_at
    }
  end
end
