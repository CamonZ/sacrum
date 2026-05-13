defmodule Sacrum.Realtime.Cdc.WalExConsumer do
  @moduledoc """
  WalEx event module that forwards committed transactions into the CDC projector.
  """

  use WalEx.Event, name: Sacrum

  alias Sacrum.Realtime.Cdc.Projector

  on_event(:all, fn events ->
    Projector.dispatch(events)
  end)
end
