defmodule GitGud.Web.CheckpointTranscriptTest do
  @moduledoc """
  Unit tests for `GitGud.Web.CheckpointTranscript`, which normalises the raw
  transcript lines of an Entire-CLI checkpoint into messages a UI can render.

  The shapes exercised here are the real ones, taken from a checkpoint the CLI
  0.11.5 pushed: the compacted `transcript.jsonl` envelope (whose user parts carry
  no `type`), the Claude Code `full.jsonl` line, the OpenCode-native line, and a
  fragment of a pretty-printed transcript that is not JSON Lines at all.
  """

  use ExUnit.Case, async: true

  alias GitGud.Web.CheckpointTranscript

  describe "message/1" do
    test "reads a compact user message, whose part carries no type" do
      line =
        ~s({"v":1,"agent":"opencode","cli_version":"0.11.5","type":"user",) <>
          ~s("ts":"2026-01-02T03:04:05.000Z","content":[{"id":"prt-1","text":"Create SECOND.md"}]})

      message = CheckpointTranscript.message(line)

      assert message.role == :user
      assert message.text == ["Create SECOND.md"]
      assert message.tools == []
      assert message.thinking == []
      assert message.tokens == nil
      assert message.raw == nil
      assert %DateTime{} = message.at
    end

    test "reads a tool call, its input and its result" do
      line =
        ~s({"v":1,"type":"assistant","ts":"2026-01-02T03:04:06.000Z",) <>
          ~s("input_tokens":49,"output_tokens":36,) <>
          ~s("content":[{"id":"functions.write:0","name":"write","type":"tool_use",) <>
          ~s("input":{"filePath":"SECOND.md","content":"second\\n"},) <>
          ~s("result":{"output":"Wrote file successfully.","status":"success"}}]})

      message = CheckpointTranscript.message(line)

      assert message.role == :assistant
      assert message.text == []
      assert [tool] = message.tools
      assert tool.name == "write"
      assert tool.status == "success"
      refute tool.error?
      assert tool.input =~ ~s("filePath": "SECOND.md")
      assert tool.output == "Wrote file successfully."
      assert message.tokens == %{input: 49, output: 36}
    end

    test "reads a compact text message" do
      line = ~s({"v":1,"type":"assistant","content":[{"text":"Done.","type":"text"}]})

      assert %{role: :assistant, text: ["Done."], at: nil} =
               CheckpointTranscript.message(line)
    end

    test "reads a thinking part" do
      line = ~s({"v":1,"type":"assistant","content":[{"type":"thinking","thinking":"hmm"}]})

      assert %{thinking: ["hmm"], text: []} = CheckpointTranscript.message(line)
    end

    test "reads a Claude Code message, whose parts sit under message.content" do
      line =
        ~s({"type":"assistant","message":{"role":"assistant",) <>
          ~s("content":[{"type":"text","text":"On it."},) <>
          ~s({"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}})

      message = CheckpointTranscript.message(line)

      assert message.role == :assistant
      assert message.text == ["On it."]
      assert [tool] = message.tools
      assert tool.name == "Bash"
      assert tool.input =~ "ls"
    end

    test "reads an OpenCode-native message" do
      line =
        ~s({"info":{"role":"assistant"},"parts":[{"type":"tool","tool":"write",) <>
          ~s("state":{"status":"completed","input":{"filePath":"a.md"},"output":"ok"}}]})

      message = CheckpointTranscript.message(line)

      assert message.role == :assistant
      assert [tool] = message.tools
      assert tool.name == "write"
      assert tool.status == "completed"
      assert tool.output == "ok"
    end

    test "marks an error result" do
      line =
        ~s({"v":1,"type":"assistant","content":[{"type":"tool_use","name":"bash",) <>
          ~s("result":{"output":"boom","status":"error"}}]})

      assert %{tools: [tool]} = CheckpointTranscript.message(line)
      assert tool.error?
    end

    test "keeps a line that is not a transcript message raw" do
      for line <- [
            "not json at all",
            ~s({"type":"summary","summary":"a title"}),
            ~s(  "info": {),
            "[]"
          ] do
        message = CheckpointTranscript.message(line)

        assert message.role == :raw
        assert message.raw == line
        assert message.text == []
        assert message.tools == []
      end
    end
  end

  describe "messages/1" do
    test "normalises a list of raw lines" do
      lines = [
        ~s({"v":1,"type":"user","content":[{"text":"hi"}]}),
        ~s({"v":1,"type":"assistant","content":[{"text":"hello"}]})
      ]

      assert [%{role: :user}, %{role: :assistant}] = CheckpointTranscript.messages(lines)
    end
  end

  describe "transcript/1" do
    test "decodes an AiderDesk document transcript" do
      # A truly pretty-printed document — one JSON object, many lines — is what
      # AiderDesk writes to `full.jsonl`, and what the CLI hands us line by line.
      document =
        Jason.encode!(
          %{
            "version" => 2,
            "contextMessages" => [
              %{
                "id" => "u1",
                "role" => "user",
                "content" => "Commit the staged diff.",
                "timestamp" => 1_792_378_904_594
              },
              %{
                "id" => "a1",
                "role" => "assistant",
                "content" => [
                  %{"type" => "reasoning", "text" => "Let me look at the diff."},
                  %{
                    "type" => "tool-call",
                    "toolCallId" => "call_1",
                    "toolName" => "code_mode",
                    "input" => %{"code" => "return git.diff()"}
                  }
                ],
                "usageReport" => %{
                  "model" => "openai-compatible/deepseek-v4.1-flash",
                  "sentTokens" => 489,
                  "receivedTokens" => 484,
                  "messageCost" => 0.00086062
                },
                "timestamp" => 1_792_378_909_910
              },
              %{
                "id" => "t1",
                "role" => "tool",
                "content" => [
                  %{
                    "type" => "tool-result",
                    "toolCallId" => "call_1",
                    "toolName" => "code_mode",
                    "output" => %{
                      "type" => "content",
                      "value" => [%{"type" => "text", "text" => "exit_code: 0"}]
                    }
                  }
                ],
                "timestamp" => 1_792_378_909_910
              },
              %{
                "id" => "a2",
                "role" => "assistant",
                "content" => [%{"type" => "text", "text" => "Committed as `853562c`."}]
              }
            ],
            "contextFiles" => []
          },
          pretty: true
        )

      assert [user, assistant, reply] = CheckpointTranscript.transcript(lines(document))

      assert %{role: :user, text: ["Commit the staged diff."]} = user
      assert %DateTime{} = user.at

      assert assistant.role == :assistant
      assert assistant.thinking == ["Let me look at the diff."]
      assert [tool] = assistant.tools
      assert tool.name == "code_mode"
      assert tool.input =~ "return git.diff()"
      # The separate `role:"tool"` entry is folded into the call it answers.
      assert tool.output == "exit_code: 0"
      assert assistant.tokens == %{input: 489, output: 484}
      assert assistant.model == "openai-compatible/deepseek-v4.1-flash"
      assert assistant.cost == 0.00086062

      assert reply.role == :assistant
      assert reply.text == ["Committed as `853562c`."]
    end

    test "folds a separate result line into its call" do
      lines = [
        ~s({"type":"assistant","message":{"role":"assistant",) <>
          ~s("content":[{"type":"tool_use","id":"call_1","name":"Bash","input":{"command":"ls"}}]}}),
        ~s({"type":"user","message":{"role":"user",) <>
          ~s("content":[{"type":"tool_result","tool_use_id":"call_1","content":"README.md"}]}})
      ]

      assert [message] = CheckpointTranscript.transcript(lines)
      assert message.role == :assistant
      assert [tool] = message.tools
      assert tool.name == "Bash"
      assert tool.output == "README.md"
    end

    test "renders a document fragment that will not decode as a single raw block" do
      document =
        Jason.encode!(%{"version" => 2, "contextMessages" => []}, pretty: true)

      # The first lines of a pretty-printed document, as a truncation would leave
      # them: no single line is a JSON object of its own.
      fragment = document |> String.split("\n") |> Enum.take(3)

      assert [%{role: :raw} = message] = CheckpointTranscript.transcript(fragment)
      assert message.raw == Enum.join(fragment, "\n")
    end
  end

  describe "label/1" do
    test "names a message's role" do
      assert CheckpointTranscript.label(%{role: :user}) == "user"
      assert CheckpointTranscript.label(%{role: :assistant}) == "assistant"
      assert CheckpointTranscript.label(%{role: :raw}) == "raw"
      assert CheckpointTranscript.label(%{role: :other}) == "entry"
    end
  end

  #
  # Helpers
  #

  # Split a document into lines the way `GitGud.Checkpoints` hands them to us.
  defp lines(document) do
    document |> String.split("\n") |> Enum.reject(&(&1 == ""))
  end
end
