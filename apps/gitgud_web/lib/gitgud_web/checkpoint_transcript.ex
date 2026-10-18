defmodule GitGud.Web.CheckpointTranscript do
  @moduledoc """
  Normalises the raw transcript lines `GitGud.Checkpoints.session/4` returns into
  messages a UI can render.

  Which shape a line takes depends on the transcript file that was read:

    * the CLI's *compacted* `transcript.jsonl` — one normalised message per line:

          {"v":1,"agent":"opencode","type":"user","ts":"…",
           "content":[{"id":"prt_…","text":"…"}]}
          {"v":1,…,"type":"assistant","input_tokens":49,"output_tokens":36,
           "content":[{"type":"tool_use","name":"write","input":{…},
                       "result":{"output":"…","status":"success"}}]}

      where `content` is a list of parts — `text`, `tool_use`, `thinking` — and a
      user part usually carries no `type` at all;
    * the agent-native `full.jsonl` in its JSON-Lines form (Claude Code), whose
      parts hang off `message.content`;
    * anything else — including OpenCode's `full.jsonl`, which is a
      pretty-printed JSON document rather than JSON Lines — is passed through
      verbatim as a `:raw` message.

  Read-only: nothing here writes back to a repository.
  """

  @type tool :: %{
          name: binary | nil,
          input: binary | nil,
          output: binary | nil,
          status: binary | nil,
          error?: boolean
        }

  @type role :: :user | :assistant | :system | :tool | :other

  @type message :: %{
          role: role | :raw,
          at: DateTime.t() | NaiveDateTime.t() | nil,
          text: [binary],
          tools: [tool],
          thinking: [binary],
          tokens: %{input: integer | nil, output: integer | nil} | nil,
          raw: binary | nil
        }

  @doc "Maps a list of raw JSON Lines onto messages."
  @spec messages([binary]) :: [message]
  def messages(lines), do: Enum.map(lines, &message/1)

  @doc "Normalises a single raw JSON Line into a message."
  @spec message(binary) :: message
  def message(line) do
    case Jason.decode(line) do
      {:ok, entry} when is_map(entry) -> build(entry, line)
      _other -> blank(:raw, line)
    end
  end

  @doc "A short human label for a message's role."
  @spec label(message | atom) :: binary
  def label(%{role: role}), do: label(role)
  def label(:user), do: "user"
  def label(:assistant), do: "assistant"
  def label(:system), do: "system"
  def label(:tool), do: "tool"
  def label(:raw), do: "raw"
  def label(_role), do: "entry"

  #
  # Helpers
  #

  defp build(entry, line) do
    {text, tools, thinking} = parts(content(entry))

    if text == [] and tools == [] and thinking == [] do
      blank(:raw, line)
    else
      %{
        role: role(entry["type"] || entry["role"] || get_in(entry, ["info", "role"])),
        at: timestamp(entry),
        text: text,
        tools: tools,
        thinking: thinking,
        tokens: tokens(entry),
        raw: nil
      }
    end
  end

  # The compact envelope carries `content`; the agent-native Claude Code line
  # buries the same list under `message.content`.
  defp content(entry) do
    case entry["content"] || entry["parts"] || entry["text"] || entry["message"] do
      %{"content" => inner} -> inner
      %{"parts" => inner} -> inner
      other -> other
    end
  end

  defp blank(:raw, line),
    do: %{role: :raw, at: nil, text: [], tools: [], thinking: [], tokens: nil, raw: line}

  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role("system"), do: :system
  defp role("tool"), do: :tool
  defp role(_role), do: :other

  defp timestamp(entry) do
    case entry["ts"] || entry["created_at"] do
      at when is_binary(at) -> parse_time(at)
      _other -> nil
    end
  end

  defp parse_time(at) do
    with {:error, _reason} <- DateTime.from_iso8601(at),
         {:error, _reason} <- NaiveDateTime.from_iso8601(at) do
      nil
    else
      {:ok, datetime, _offset} -> datetime
      {:ok, datetime} -> datetime
    end
  end

  defp tokens(entry) do
    case {entry["input_tokens"], entry["output_tokens"]} do
      {nil, nil} -> nil
      {input, output} -> %{input: input, output: output}
    end
  end

  defp parts(content) when is_binary(content), do: {[content], [], []}

  defp parts(content) when is_list(content),
    do: Enum.reduce(content, {[], [], []}, fn part, acc -> part(part, acc) end)

  defp parts(_content), do: {[], [], []}

  defp part(%{"type" => "text"} = part, {text, tools, thinking}) do
    case part["text"] do
      text? when is_binary(text?) -> {text ++ [text?], tools, thinking}
      _other -> {text, tools, thinking}
    end
  end

  defp part(%{"type" => "thinking"} = part, {text, tools, thinking}) do
    case part["thinking"] || part["text"] do
      text? when is_binary(text?) -> {text, tools, thinking ++ [text?]}
      _other -> {text, tools, thinking}
    end
  end

  defp part(%{"type" => type} = part, {text, tools, thinking}) when type in ["tool_use", "tool"],
    do: {text, tools ++ [tool(part)], thinking}

  defp part(%{"type" => "tool_result"} = part, {text, tools, thinking}) do
    tool = %{
      name: nil,
      input: nil,
      output: display(part["content"] || part["output"]),
      status: nil,
      error?: part["is_error"] == true
    }

    {text, tools ++ [tool], thinking}
  end

  # A compact *user* part carries no `type` — only an id and its text.
  defp part(%{"text" => text?}, {text, tools, thinking}) when is_binary(text?),
    do: {text ++ [text?], tools, thinking}

  defp part(_part, acc), do: acc

  # OpenCode-native: `{"type":"tool","tool":"write","state":{…}}`.
  defp tool(%{"tool" => name} = part) when is_binary(name) do
    state = part["state"] || %{}

    %{
      name: name,
      input: display(state["input"]),
      output: display(state["output"]),
      status: state["status"],
      error?: false
    }
  end

  defp tool(part) do
    result = part["result"] || %{}

    %{
      name: part["name"] || part["tool"],
      input: display(part["input"]),
      output: display(result["output"] || result["content"]),
      status: result["status"],
      error?: result["status"] == "error"
    }
  end

  defp display(nil), do: nil
  defp display(content) when is_binary(content), do: content

  defp display(content) when is_map(content) or is_list(content),
    do: Jason.encode!(content, pretty: true)

  defp display(content), do: to_string(content)
end
