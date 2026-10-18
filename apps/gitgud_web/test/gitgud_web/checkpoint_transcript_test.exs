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

  describe "label/1" do
    test "names a message's role" do
      assert CheckpointTranscript.label(%{role: :user}) == "user"
      assert CheckpointTranscript.label(%{role: :assistant}) == "assistant"
      assert CheckpointTranscript.label(%{role: :raw}) == "raw"
      assert CheckpointTranscript.label(%{role: :other}) == "entry"
    end
  end
end
