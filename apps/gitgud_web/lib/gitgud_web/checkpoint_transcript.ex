defmodule GitGud.Web.CheckpointTranscript do
  @moduledoc """
  Normalises the raw transcript lines `GitGud.Checkpoints.session/4` returns into
  messages a UI can render.

  Which shape a transcript takes depends on the CLI *and* the agent:

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
    * a *document* rather than JSON Lines. AiderDesk writes a pretty-printed
      `{"version":2,"contextMessages":[…]}` whose entries carry `reasoning` /
      `text` / `tool-call` parts and whose tool *results* arrive as separate
      `role:"tool"` entries; OpenCode writes a pretty-printed `info`/`parts`
      document. A transcript whose lines join into a single JSON document is
      decoded as one (`transcript/1`);
    * anything else is passed through verbatim as a `:raw` message.

  `transcript/1` is the entry point a UI wants: it takes the raw lines, decodes a
  whole-document transcript when there is one, and folds each `role:"tool"` result
  into the tool call it answers (`toolCallId`), so a call renders once, with its
  input and its output together.

  Read-only: nothing here writes back to a repository.
  """

  @type tool :: %{
          call_id: binary | nil,
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
          model: binary | nil,
          cost: float | nil,
          raw: binary | nil
        }

  @doc """
  Maps the raw lines of one session's transcript onto messages.

  When the lines join into a single JSON document (AiderDesk, or any agent that
  writes a pretty-printed transcript) the whole document is decoded; otherwise
  each line is parsed on its own. Each tool result is then folded into the tool
  call it answers.
  """
  @spec transcript([binary]) :: [message]
  def transcript(lines) when is_list(lines) do
    content = Enum.join(lines, "\n")

    case document(content) do
      {:ok, messages} ->
        merge_tool_results(messages)

      :error ->
        # Not a decodable document. If no line is even a JSON object it is a
        # document *fragment* (say, a transcript truncated past `:max_bytes`), so
        # render it as one block rather than one card per line.
        if Enum.any?(lines, &json_object?/1) do
          lines |> Enum.map(&message/1) |> merge_tool_results()
        else
          [blank(:raw, content)]
        end
    end
  end

  defp json_object?(line) do
    case Jason.decode(line) do
      {:ok, value} when is_map(value) -> true
      _other -> false
    end
  end

  @doc "Maps a list of raw JSON Lines onto messages."
  @spec messages([binary]) :: [message]
  def messages(lines), do: transcript(lines)

  @doc "Normalises a single raw JSON Line into a message."
  @spec message(binary) :: message
  def message(line) do
    case Jason.decode(line) do
      {:ok, entry} when is_map(entry) -> entry_message(entry) || blank(:raw, line)
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
  # Whole-document transcripts
  #

  # A transcript that is one pretty-printed JSON document, rather than JSON
  # Lines: AiderDesk's `contextMessages`, a `messages` list, a bare message, or a
  # list of messages. Anything else (a JSON Lines transcript, an unparseable
  # fragment) is left to the per-line path.
  defp document(content) do
    case Jason.decode(content) do
      {:ok, %{"contextMessages" => entries}} when is_list(entries) -> document_entries(entries)
      {:ok, %{"messages" => entries}} when is_list(entries) -> document_entries(entries)
      {:ok, entry} when is_map(entry) -> document_entries([entry])
      {:ok, entries} when is_list(entries) -> document_entries(entries)
      _other -> :error
    end
  end

  defp document_entries(entries) do
    messages = Enum.map(entries, &document_message/1)

    # If not a single entry is a message, this is not a transcript document and
    # the per-line path should have it.
    if Enum.any?(messages, &(&1.role != :raw)), do: {:ok, messages}, else: :error
  end

  defp document_message(entry) when is_map(entry),
    do: entry_message(entry) || blank(:raw, Jason.encode!(entry, pretty: true))

  defp document_message(other), do: blank(:raw, Jason.encode!(other, pretty: true))

  #
  # Tool calls and their results
  #

  # A tool result — an AiderDesk `role:"tool"` entry, a Claude Code `tool_result`
  # line — arrives as its own message. Fold it into the call it answers (matched
  # on the call id) and drop the standalone result message, so the call renders
  # once with both its input and its output.
  defp merge_tool_results(messages) do
    results = collect_results(messages)

    messages
    |> Enum.reduce({[], MapSet.new()}, fn message, {acc, seen} ->
      message = %{message | tools: Enum.map(message.tools, &attach_result(&1, results))}

      if result_only?(message, seen) do
        {acc, seen}
      else
        {[message | acc], Enum.reduce(message.tools, seen, &remember_call/2)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # Only tools that carry an output are *results*. The first one wins, so an
  # inline result (the compact envelope nests it in the call) is not overwritten.
  defp collect_results(messages) do
    Enum.reduce(messages, %{}, fn message, acc ->
      Enum.reduce(message.tools, acc, fn
        %{call_id: id, output: output} = tool, acc when is_binary(id) and not is_nil(output) ->
          Map.put_new(acc, id, tool)

        _tool, acc ->
          acc
      end)
    end)
  end

  defp attach_result(%{call_id: id} = tool, results) when is_binary(id) do
    case Map.get(results, id) do
      nil ->
        tool

      result ->
        %{
          tool
          | output: tool.output || result.output,
            status: tool.status || result.status,
            error?: tool.error? or result.error?
        }
    end
  end

  defp attach_result(tool, _results), do: tool

  # A message that carries nothing but results of calls already seen.
  defp result_only?(%{text: [], thinking: [], tools: [_ | _] = tools}, seen) do
    Enum.all?(tools, fn
      %{call_id: id} when is_binary(id) -> MapSet.member?(seen, id)
      _tool -> false
    end)
  end

  defp result_only?(_message, _seen), do: false

  defp remember_call(%{call_id: id}, seen) when is_binary(id), do: MapSet.put(seen, id)
  defp remember_call(_tool, seen), do: seen

  #
  # Messages
  #

  defp entry_message(entry) do
    {text, tools, thinking} = parts(content(entry))

    if text == [] and tools == [] and thinking == [] do
      nil
    else
      %{
        role: role_of(entry),
        at: timestamp(entry),
        text: text,
        tools: tools,
        thinking: thinking,
        tokens: tokens(entry),
        model: model(entry),
        cost: cost(entry),
        raw: nil
      }
    end
  end

  # The compact envelope carries `content`; the agent-native Claude Code line
  # buries the same list under `message.content`; the OpenCode-native document
  # calls it `parts`.
  defp content(entry) do
    case entry["content"] || entry["parts"] || entry["text"] || entry["message"] do
      %{"content" => inner} -> inner
      %{"parts" => inner} -> inner
      other -> other
    end
  end

  defp blank(:raw, line) do
    %{
      role: :raw,
      at: nil,
      text: [],
      tools: [],
      thinking: [],
      tokens: nil,
      model: nil,
      cost: nil,
      raw: line
    }
  end

  defp role_of(entry),
    do:
      role(
        entry["type"] || entry["role"] || nested(entry, ["info", "role"]) ||
          nested(entry, ["message", "role"])
      )

  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role("system"), do: :system
  defp role("tool"), do: :tool
  defp role(_role), do: :other

  # Read a nested field without tripping over an intermediate that is not a map.
  defp nested(map, path) when is_map(map) do
    Enum.reduce(path, map, fn
      key, acc when is_map(acc) -> acc[key]
      _key, _acc -> nil
    end)
  end

  defp nested(_other, _path), do: nil

  #
  # Timestamps, tokens, model
  #

  defp timestamp(entry) do
    case entry["ts"] || entry["created_at"] || entry["timestamp"] do
      at when is_binary(at) -> parse_time(at)
      at when is_integer(at) -> parse_epoch(at)
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

  # AiderDesk stamps messages with epoch milliseconds (a bare integer).
  defp parse_epoch(value) do
    unit = if value > 100_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  # The compact envelope carries `input_tokens`/`output_tokens`; AiderDesk
  # reports them per message in `usageReport`.
  defp tokens(entry) do
    case {input_tokens(entry), output_tokens(entry)} do
      {nil, nil} -> nil
      {input, output} -> %{input: input, output: output}
    end
  end

  defp input_tokens(entry), do: entry["input_tokens"] || usage(entry)["sentTokens"]
  defp output_tokens(entry), do: entry["output_tokens"] || usage(entry)["receivedTokens"]

  defp model(entry), do: presence(usage(entry)["model"] || entry["model"])

  defp cost(entry) do
    case usage(entry)["messageCost"] do
      cost when is_number(cost) and cost > 0 -> cost
      _other -> nil
    end
  end

  defp usage(entry) do
    case entry["usageReport"] do
      usage when is_map(usage) -> usage
      _other -> %{}
    end
  end

  defp presence(value) when value in [nil, ""], do: nil
  defp presence(value), do: value

  #
  # Parts
  #

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

  defp part(%{"type" => type} = part, {text, tools, thinking})
       when type in ["thinking", "reasoning"] do
    case part["thinking"] || part["text"] do
      text? when is_binary(text?) -> {text, tools, thinking ++ [text?]}
      _other -> {text, tools, thinking}
    end
  end

  defp part(%{"type" => "tool-call"} = part, {text, tools, thinking}),
    do: {text, tools ++ [tool_call(part)], thinking}

  defp part(%{"type" => type} = part, {text, tools, thinking}) when type in ["tool_use", "tool"],
    do: {text, tools ++ [tool(part)], thinking}

  defp part(%{"type" => "tool-result"} = part, {text, tools, thinking}),
    do: {text, tools ++ [tool_result(part)], thinking}

  defp part(%{"type" => "tool_result"} = part, {text, tools, thinking}) do
    tool = %{
      call_id: part["tool_use_id"] || part["tool_call_id"] || part["toolCallId"],
      name: part["name"],
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

  # AiderDesk: `{"type":"tool-call","toolCallId":…,"toolName":…,"input":{…}}`. The
  # result arrives later, as its own `role:"tool"` message.
  defp tool_call(part) do
    %{
      call_id: part["toolCallId"],
      name: part["toolName"] || part["name"],
      input: display(part["input"]),
      output: nil,
      status: nil,
      error?: false
    }
  end

  # AiderDesk: `{"type":"tool-result","toolCallId":…,"toolName":…,
  # "output":{"type":"content","value":[{"type":"text","text":…}]}}`.
  defp tool_result(part) do
    %{
      call_id: part["toolCallId"],
      name: part["toolName"],
      input: nil,
      output: output_text(part["output"]),
      status: nil,
      error?: false
    }
  end

  # OpenCode-native: `{"type":"tool","tool":"write","state":{…}}`.
  defp tool(%{"tool" => name} = part) when is_binary(name) do
    state = part["state"] || %{}

    %{
      call_id: part["callID"] || part["id"],
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
      call_id: part["id"] || part["toolCallId"],
      name: part["name"] || part["tool"],
      input: display(part["input"]),
      output: display(result["output"] || result["content"]),
      status: result["status"],
      error?: result["status"] == "error"
    }
  end

  defp output_text(nil), do: nil

  defp output_text(%{"value" => value}) when is_list(value) do
    value
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      other -> display(other)
    end)
    |> Enum.join("\n")
  end

  defp output_text(output), do: display(output)

  defp display(nil), do: nil
  defp display(content) when is_binary(content), do: content

  defp display(content) when is_map(content) or is_list(content),
    do: Jason.encode!(content, pretty: true)

  defp display(content), do: to_string(content)
end
