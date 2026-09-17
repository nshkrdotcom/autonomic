defmodule CodingAgentFixture.AuthTest do
  use ExUnit.Case, async: true
  alias CodingAgentFixture.Auth

  test "accepts only the valid fixture token" do
    assert Auth.valid_token?("valid")
    refute Auth.valid_token?("invalid")
  end
end
