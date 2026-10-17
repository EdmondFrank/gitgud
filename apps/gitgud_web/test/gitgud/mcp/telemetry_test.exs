defmodule GitGud.MCP.TelemetryTest do
  @moduledoc """
  Tests for the MCP tool-call telemetry (see `guides/MCP.md` §11, Phase 6).

  A test handler is attached to the `[:gitgud, :mcp, :tool, :call, :*]` events
  and forwards them to the test process, so the emitted measurements/metadata
  can be asserted without a running MCP session.
  """

  use GitGud.Web.ConnCase, async: false
  use GitGud.Web.DataFactory

  alias Anubis.Server.Frame

  alias GitGud.User

  alias GitGud.MCP.ServerHelpers
  alias GitGud.MCP.Telemetry

  @handler_id "mcp-telemetry-test"

  setup do
    test_pid = self()

    :telemetry.attach_many(
      @handler_id,
      [Telemetry.event_prefix() ++ [:start], Telemetry.event_prefix() ++ [:stop]],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      %{}
    )

    on_exit(fn -> :telemetry.detach(@handler_id) end)

    %{user: User.create!(factory(:user))}
  end

  test "span/2 emits :start and :stop with the duration and metadata" do
    assert {:ok, :value} = Telemetry.span(%{tool: "whoami"}, fn -> {{:ok, :value}, :ok} end)

    assert_receive {:telemetry, [:gitgud, :mcp, :tool, :call, :start], _measurements,
                    %{tool: "whoami"}}

    assert_receive {:telemetry, [:gitgud, :mcp, :tool, :call, :stop], %{duration: duration},
                    %{tool: "whoami", result: :ok}}

    assert is_integer(duration)
  end

  test "span/2 returns the wrapped value unchanged", %{user: user} do
    frame = Frame.new(%{current_user: user})

    assert {:reply, :response, ^frame} =
             Telemetry.span(%{tool: "t"}, fn -> {{:reply, :response, frame}, :ok} end)
  end

  test "an allowed tools/call is reported as :ok", %{user: user} do
    frame = Frame.new(%{current_user: user, mcp_scopes: ["user:read"]})
    request = %{"method" => "tools/call", "params" => %{"name" => "whoami", "arguments" => %{}}}

    assert {:reply, _response, _frame} =
             ServerHelpers.handle_request_with_filtered_tools(GitGud.MCP.Server, request, frame)

    assert_receive {:telemetry, [:gitgud, :mcp, :tool, :call, :stop], %{duration: _duration},
                    metadata}

    assert metadata.tool == "whoami"
    assert metadata.result == :ok
    assert metadata.user_id == user.id
    assert metadata.scopes == ["user:read"]
  end

  test "a call outside the granted scopes is reported as :denied", %{user: user} do
    frame = Frame.new(%{current_user: user, mcp_scopes: ["issue:read"]})

    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "create_issue", "arguments" => %{}}
    }

    assert {:error, _error, _frame} =
             ServerHelpers.handle_request_with_filtered_tools(GitGud.MCP.Server, request, frame)

    assert_receive {:telemetry, [:gitgud, :mcp, :tool, :call, :stop], _measurements, metadata}

    assert metadata.tool == "create_issue"
    assert metadata.result == :denied
    assert metadata.scopes == ["issue:read"]
  end

  test "session/bearer credentials report a nil scope list", %{user: user} do
    frame = Frame.new(%{current_user: user, mcp_scopes: nil})
    request = %{"method" => "tools/call", "params" => %{"name" => "whoami", "arguments" => %{}}}

    assert {:reply, _response, _frame} =
             ServerHelpers.handle_request_with_filtered_tools(GitGud.MCP.Server, request, frame)

    assert_receive {:telemetry, [:gitgud, :mcp, :tool, :call, :stop], _measurements, metadata}

    assert metadata.result == :ok
    assert metadata.scopes == nil
  end
end
