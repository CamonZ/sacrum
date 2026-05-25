defmodule Sacrum.ChatSessionRunner.DirectTracker.RejectionsTest do
  use ExUnit.Case, async: true

  alias Sacrum.ChatSessionRunner.DirectTracker.Rejections

  test "formats ambiguous target rejection guidance" do
    rejection = %{
      "reason_code" => "ambiguous_target",
      "details" => "Matched 123e4567-e89b-12d3-a456-426614174000"
    }

    reason = Rejections.public_reason(rejection)

    assert reason == "ambiguous_target"
    assert Rejections.public_message(reason, rejection) =~ "Multiple tracker objects match"
  end
end
