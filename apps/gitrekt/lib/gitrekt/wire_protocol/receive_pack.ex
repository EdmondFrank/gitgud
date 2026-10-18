defmodule GitRekt.WireProtocol.ReceivePack do
  @moduledoc """
  Module implementing the `git-receive-pack` command.

  The service walks `:disco` → `:update_req` → `:pack` → `:done`; the `:pack` step
  is skipped for a push that only deletes references, which carries no packfile
  at all (see `next/2`).
  """

  @behaviour GitRekt.WireProtocol

  alias GitRekt.Git
  alias GitRekt.GitAgent
  alias GitRekt.GitRepo

  require Logger

  import GitRekt.WireProtocol, only: [reference_discovery: 4, valid_reference_name?: 1]

  @service_name "git-receive-pack"

  @null_oid String.duplicate("0", 40)

  defstruct agent: nil,
            state: :disco,
            caps: [],
            cmds: [],
            repo: nil,
            hide_references: [],
            reference_policy: nil,
            writepack: nil,
            writepack_progress: %{
              total_objects: 0,
              indexed_objects: 0,
              received_objects: 0,
              local_objects: 0,
              total_deltas: 0,
              indexed_deltas: 0,
              received_bytes: 0
            }

  @type cmd ::
          {:create, Git.oid(), binary}
          | {:update, Git.oid(), Git.oid(), binary}
          | {:delete, Git.oid(), binary}

  @typedoc """
  Validates a reference a push would write, before it is written.

  Returns `:ok` to accept it, or `{:error, reason}` to report it back to the
  client as rejected (`ng <ref> <reason>`). `nil` accepts every valid reference
  name. Deletions are never offered to the policy, so a reference can always be
  removed.
  """
  @type reference_policy :: (binary -> :ok | {:error, binary}) | nil

  @type t :: %__MODULE__{
          agent: GitAgent.agent(),
          state: :disco | :update_req | :pack | :buffer | :done,
          caps: [binary],
          cmds: [cmd],
          repo: GitRepo.t(),
          hide_references: [binary],
          reference_policy: reference_policy,
          writepack: GitWritePack.t(),
          writepack_progress: Git.odb_writepack_progress()
        }

  #
  # Callbacks
  #

  @impl true
  def next(%__MODULE__{state: :disco} = handle, [:flush | lines]) do
    {%{handle | state: :done, caps: []}, lines, discovery(handle)}
  end

  def next(%__MODULE__{state: :disco} = handle, lines) do
    {%{handle | state: :update_req, caps: []}, lines, discovery(handle)}
  end

  def next(%__MODULE__{state: :update_req} = handle, [:flush | lines]) do
    {%{handle | state: :done}, lines, []}
  end

  def next(%__MODULE__{state: :update_req} = handle, lines) do
    case GitAgent.odb_writepack(handle.agent) do
      {:ok, writepack} ->
        {shallows, lines} = Enum.split_while(lines, &match?({:shallow, _oid}, &1))

        if Enum.empty?(shallows) do
          {cmds, lines} = Enum.split_while(lines, &is_binary/1)
          {caps, cmds} = parse_caps(cmds)
          [:flush | lines] = lines

          handle = %{
            handle
            | caps: caps,
              cmds: parse_cmds(cmds),
              writepack: writepack
          }

          # A push that only deletes references carries no packfile at all: `git
          # send-pack` sets `need_pack_data = 0` (a deletion needs no objects) and
          # closes the stream right after the command list. Waiting in `:pack` for
          # a pack that never arrives is what used to hang every `git push
          # --delete` -- and `entire checkpoint delete`. There is nothing left to
          # read, so go straight to `:done` and report the status; a pack is still
          # consumed when a client sends one anyway.
          if delete_only?(handle.cmds) and Enum.empty?(lines) do
            {%{handle | state: :done}, lines, []}
          else
            {%{handle | state: :pack}, lines, []}
          end
        else
          raise "shallow update not allowed"
        end

      {:error, error} ->
        raise error
    end
  end

  def next(%__MODULE__{state: :pack} = handle, [{:pack, pack_data}]) do
    case GitAgent.odb_writepack_append(
           handle.agent,
           handle.writepack,
           pack_data,
           handle.writepack_progress
         ) do
      {:ok, progress} when progress.received_objects == progress.total_objects ->
        {%{handle | state: :done, writepack_progress: progress}, [], []}

      {:ok, progress} ->
        {%{handle | state: :buffer, writepack_progress: progress}, [], []}

      {:error, error} ->
        raise error
    end
  end

  def next(%__MODULE__{state: :pack} = handle, []) do
    {%{handle | state: :done}, [], []}
  end

  def next(%__MODULE__{state: :buffer} = handle, pack_data) do
    {%{handle | state: :pack}, [{:pack, pack_data}], []}
  end

  def next(%__MODULE__{state: :done} = handle, []) do
    if handle.cmds != [] do
      {accepted, rejected} = partition_cmds(handle.cmds, handle.reference_policy)

      with :ok <- push_pack(handle.agent, handle.writepack, handle.writepack_progress),
           :ok <- push_cmds(handle.agent, accepted),
           {:ok, repo} <- GitRepo.push(handle.repo, accepted) do
        {%{handle | repo: repo}, [], report_status(handle, accepted, rejected)}
      else
        {:error, reason} ->
          {handle, [], ["unpack #{inspect(reason)}"]}
      end
    else
      {handle, [], []}
    end
  end

  @impl true
  def skip(%__MODULE__{state: :disco} = handle), do: %{handle | state: :update_req, caps: []}
  def skip(%__MODULE__{state: :update_req} = handle), do: %{handle | state: :pack}
  def skip(%__MODULE__{state: :pack} = handle), do: %{handle | state: :done}
  def skip(%__MODULE__{state: :done} = handle), do: handle

  #
  # Helpers
  #

  # The advertisement honors the reference exclusions the caller configured (see
  # `GitRekt.WireProtocol.reference_discovery/4`).
  defp discovery(handle) do
    reference_discovery(handle.agent, @service_name, handle.caps,
      hide_references: handle.hide_references
    )
  end

  defp parse_cmds(cmds) do
    Enum.map(cmds, fn cmd ->
      case String.split(cmd, " ", parts: 3) do
        [@null_oid, new, name] ->
          {:create, Git.oid_parse(new), name}

        [old, @null_oid, name] ->
          {:delete, Git.oid_parse(old), name}

        [old, new, name] ->
          {:update, Git.oid_parse(old), Git.oid_parse(new), name}
      end
    end)
  end

  defp parse_caps([]), do: {[], []}

  defp parse_caps([first_ref | refs]) do
    case String.split(first_ref, "\0", parts: 2) do
      [first_ref] -> {[], [first_ref | refs]}
      [first_ref, caps] -> {String.split(caps, " ", trim: true), [first_ref | refs]}
    end
  end

  defp report_status(%__MODULE__{caps: caps}, accepted, rejected) do
    if "report-status" in caps,
      do:
        List.flatten([
          "unpack ok",
          Enum.map(accepted, &"ok #{cmd_name(&1)}"),
          Enum.map(rejected, fn {name, reason} -> "ng #{name} #{reason}" end),
          :flush
        ]),
      else: []
  end

  defp push_pack(_agent, _writepack, progress) when progress.received_bytes == 0, do: :ok

  defp push_pack(agent, writepack, progress) do
    case GitAgent.odb_writepack_commit(agent, writepack, progress) do
      {:ok, _progress} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp push_cmds(agent, cmds) do
    GitAgent.transaction(agent, fn agent -> Enum.each(cmds, &push_cmd(agent, &1)) end)
  end

  defp push_cmd(agent, {:create, new_oid, name}),
    do: :ok = GitAgent.reference_create(agent, name, :oid, new_oid)

  defp push_cmd(agent, {:update, _old_oid, new_oid, name}),
    do: :ok = GitAgent.reference_create(agent, name, :oid, new_oid, force: true)

  defp push_cmd(agent, {:delete, _old_oid, name}),
    do: :ok = GitAgent.reference_delete(agent, name)

  # Git's own `delete_only()`. An empty command list is *not* one: a client with
  # nothing to send is handled by the `[:flush | lines]` clause above, so an empty
  # list reaching here would be a truncated request.
  defp delete_only?([]), do: false
  defp delete_only?(cmds), do: Enum.all?(cmds, &match?({:delete, _old_oid, _name}, &1))

  # Splits the incoming commands into the ones to apply and the ones to report back
  # as rejected. Only writes are offered to the policy: a deletion never adds data,
  # so it is always accepted -- which is also what lets a deployment that turned
  # checkpoint reading off still be cleaned up.
  defp partition_cmds(cmds, policy) do
    {accepted, rejected} =
      Enum.reduce(cmds, {[], []}, fn cmd, {accepted, rejected} ->
        case validate_cmd(cmd, policy) do
          :ok -> {[cmd | accepted], rejected}
          {:error, reason} -> {accepted, [{cmd_name(cmd), reason} | rejected]}
        end
      end)

    {Enum.reverse(accepted), Enum.reverse(rejected)}
  end

  defp validate_cmd({:delete, _old_oid, _name}, _policy), do: :ok

  defp validate_cmd(cmd, policy) do
    name = cmd_name(cmd)

    cond do
      not valid_reference_name?(name) -> {:error, "invalid-reference-name"}
      is_nil(policy) -> :ok
      true -> policy.(name) |> normalize_policy_result()
    end
  end

  defp normalize_policy_result(:ok), do: :ok
  defp normalize_policy_result({:error, reason}), do: {:error, to_string(reason)}
  defp normalize_policy_result(_other), do: :ok

  defp cmd_name(cmd), do: elem(cmd, tuple_size(cmd) - 1)
end
