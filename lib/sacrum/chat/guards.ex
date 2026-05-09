defmodule Sacrum.Chat.Guards do
  @moduledoc """
  Shared guards for V0 chat persistence helpers.
  """

  defguard is_user_project_scope(user_id, project_id)
           when is_binary(user_id) and is_binary(project_id)

  defguard is_session_scope(user_id, project_id, chat_session_id)
           when is_user_project_scope(user_id, project_id) and is_binary(chat_session_id)

  defguard is_attrs(attrs) when is_map(attrs)
  defguard is_options(opts) when is_list(opts)
end
