defmodule SacrumWeb.TaskSectionJSON do
  alias Sacrum.Repo.Schemas.TaskSection

  def index(%{sections: sections}) do
    %{data: for(section <- sections, do: data(section))}
  end

  def show(%{section: section}) do
    %{data: data(section)}
  end

  defp data(%TaskSection{} = section) do
    %{
      id: section.id,
      task_id: section.task_id,
      section_type: section.section_type,
      content: section.content,
      section_order: section.section_order,
      done: section.done,
      done_at: section.done_at,
      inserted_at: section.inserted_at,
      updated_at: section.updated_at
    }
  end
end
