defmodule GitRekt.WireProtocol.ReceivePack do
  @moduledoc """
  Module implementing the `git-receive-pack` command.
  """

  @behaviour GitRekt.WireProtocol

  alias GitRekt.Git
  alias GitRekt.GitAgent
  alias GitRekt.Packfile

  require Logger

  import GitRekt.WireProtocol, only: [reference_discovery: 2]

  @service_name "git-receive-pack"

  @null_oid String.duplicate("0", 40)
  @null_iter {0, 0, ""}

  defstruct [
    :agent,
    :callback,
    state: :disco,
    caps: [],
    cmds: [],
    pack: [],
    pack_iter: @null_iter,
    pack_data: "PACK",
    pack_odb_writer: nil,
    pack_odb_writer_progress: %{
      total_objects: 0,
      indexed_objects: 0,
      received_objects: 0,
      local_objects: 0,
      total_deltas: 0,
      indexed_deltas: 0,
      received_bytes: 0,
    },
    pack_odb_writer_buffer: "PACK"
  ]

  @type callback :: {module, [term]} | nil

  @type cmd :: {:create, Git.oid, binary} | {:update, Git.oid, Git.oid, binary} | {:delete, Git.oid, binary}

  @type t :: %__MODULE__{
    agent: GitAgent.agent,
    callback: callback,
    state: :disco | :update_req | :pack | :buffer | :done,
    caps: [binary],
    cmds: [cmd],
    pack: Packfile.obj_list,
    pack_iter: Packfile.obj_iter,
    pack_data: binary,
    pack_odb_writer: Git.odb_writepack,
    pack_odb_writer_progress: Git.odb_writepack_progress,
    pack_odb_writer_buffer: binary
  }

  @doc """
  Applies the given `receive_pack` *PACK* to the repository.
  """
  @spec apply_pack(t, :write | :write_dump | :write_pack | :write_pack_dump | :commit_pack | :commit_pack_dump) :: {:ok, [Git.oid] | map} | {:error, term}
  def apply_pack(%__MODULE__{agent: agent, pack: pack} = receive_pack, mode \\ :write) do
    {objs, delta_refs} = resolve_pack(pack)
    pack = Map.values(objs) ++ Enum.map(delta_refs, &{:delta_reference, &1}) # TODO
    GitAgent.transaction(agent, nil, fn agent ->
      case GitAgent.odb(agent) do
        {:ok, odb} ->
          odb_apply_pack(agent, odb, pack, receive_pack, mode)
        {:error, reason} ->
          {:error, reason}
      end
    end, timeout: :infinity)
  end

  @doc """
  Applies the given `receive_pack` commands to the repository.
  """
  @spec apply_cmds(t) :: :ok | {:error, term}
  def apply_cmds(%__MODULE__{agent: agent, cmds: cmds} = _receive_pack) do
    GitAgent.transaction(agent, fn agent ->
      Enum.each(cmds, fn
        {:create, new_oid, name} ->
          :ok = GitAgent.reference_create(agent, name, :oid, new_oid)
        {:update, _old_oid, new_oid, name} ->
          :ok = GitAgent.reference_create(agent, name, :oid, new_oid, force: true)
        {:delete, _old_oid, name} ->
          :ok = GitAgent.reference_delete(agent, name)
      end)

      case GitAgent.empty?(agent) do
        {:ok, true} ->
          GitAgent.reference_create(agent, "HEAD", :symbolic, "refs/heads/master", force: true)
        {:ok, false} ->
          :ok
        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Returns the Git objects and Git delta-references for the given `receive_pack`.
  """
  @spec resolve_pack([Packfile.obj]) :: {map, [term]}
  def resolve_pack(pack) do
    {delta_refs, objs} = Enum.split_with(pack, &match?({:delta_reference, _delta_ref}, &1))
    batch_resolve_objects(Map.new(objs, &{odb_object_hash(&1), &1}), Enum.map(delta_refs, fn {:delta_reference, delta_ref} -> delta_ref end))
  end

  @doc """
  Returns the Git objects and Git delta-references for the given `objs` and `delta_refs`.
  """
  @spec resolve_delta_objects(map, [term]) :: {map, [term]}
  def resolve_delta_objects(objs, delta_refs), do: batch_resolve_objects(objs, delta_refs)

  #
  # Callbacks
  #

  @impl true
  def next(%__MODULE__{state: :disco} = handle, [:flush|lines]) do
    {%{handle|state: :done}, lines, reference_discovery(handle.agent, @service_name)}
  end

  def next(%__MODULE__{state: :disco} = handle, lines) do
    {%{handle|state: :update_req}, lines, reference_discovery(handle.agent, @service_name)}
  end

  def next(%__MODULE__{state: :update_req} = handle, [:flush|lines]) do
    {%{handle|state: :done}, lines, []}
  end

  def next(%__MODULE__{state: :update_req} = handle, lines) do
    {_shallows, lines} = Enum.split_while(lines, &odb_object_match?(&1, :shallow))
    {cmds, lines} = Enum.split_while(lines, &is_binary/1)
    {caps, cmds} = parse_caps(cmds)
    [:flush|lines] = lines
    {:ok, odb} = GitAgent.odb(handle.agent)
    {:ok, writepack} = GitAgent.odb_writepack(handle.agent, odb)
    {%{handle|state: :pack, caps: caps, cmds: parse_cmds(cmds), pack_odb_writer: writepack}, lines, []}
  end

  def next(%__MODULE__{state: :pack} = handle, [{:pack, pack_data}]) do
    handle = odb_writepack_append(handle, pack_data)
    case Packfile.parse(pack_data, handle.pack_iter) do
      {:pack, pack} ->
        {%{handle|state: :done, pack: handle.pack ++ pack, pack_data: handle.pack_data <> pack_data, pack_iter: @null_iter}, [], []}
      {:buffer, pack, iter} ->
        {%{handle|state: :buffer, pack: handle.pack ++ pack, pack_data: handle.pack_data <> pack_data, pack_iter: iter}, [], []}
    end
  end

  def next(%__MODULE__{state: :buffer} = handle, pack_data) do
    {%{handle|state: :pack}, [{:pack, pack_data}], []}
  end

  def next(%__MODULE__{state: :done} = handle, []) do
    case odb_flush(handle) do
      :ok ->
        {handle, [], report_status(handle)}
      {:error, reason} ->
        {handle, [], ["unpack #{inspect reason}"]}
    end
  end

  @impl true
  def skip(%__MODULE__{state: :disco} = handle), do: %{handle|state: :update_req}
  def skip(%__MODULE__{state: :update_req} = handle), do: %{handle|state: :pack}
  def skip(%__MODULE__{state: :pack} = handle), do: %{handle|state: :done}
  def skip(%__MODULE__{state: :done} = handle), do: handle

  #
  # Helpers
  #


  defp odb_writepack_append(%__MODULE__{pack_odb_writer: writepack, pack_odb_writer_progress: progress, pack_odb_writer_buffer: buffer} = handle, data) do
    case Git.odb_writepack_append(writepack, buffer <> data, progress) do
      {:ok, progress} ->
        progress = Map.update!(progress, :received_bytes, &(&1 + byte_size(data)))
        %{handle|pack_odb_writer_progress: progress, pack_odb_writer_buffer: ""}
      {:error, reason} ->
        Logger.warn("Cannot append to writepack: #{inspect reason}")
        %{handle|pack_odb_writer_buffer: handle.pack_odb_writer_buffer <> data}
    end
  end

  defp odb_apply_pack(agent, odb, pack, _receive_pack, mode) when mode in [:write, :write_dump] do
    {:ok, Enum.map(pack, &apply_pack_obj(agent, odb, &1, mode))}
  end

  defp odb_apply_pack(agent, odb, pack, %__MODULE__{pack_data: pack_data}, mode) when mode in [:write_pack, :write_pack_dump] do
    case GitAgent.odb_write_pack(agent, odb, pack_data) do
      :ok ->
        {:ok, Enum.map(pack, &apply_pack_obj(agent, odb, &1, mode))}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp odb_apply_pack(agent, odb, pack, %__MODULE__{pack_odb_writer: writepack, pack_odb_writer_progress: progress}, mode) when mode in [:commit_pack, :commit_pack_dump] do
    case Git.odb_writepack_commit(writepack, progress) do
      {:ok, _progress} ->
        {:ok, Enum.map(pack, &apply_pack_obj(agent, odb, &1, mode))}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp odb_flush(%__MODULE__{cmds: [], pack: []}), do: :ok
  defp odb_flush(%__MODULE__{callback: {module, args}} = handle) do
    case apply(module, :push_pack, args ++ [handle]) do
      {:ok, agent, cmds, objs} ->
        apply(module, :push_meta, args ++ [agent, cmds, objs])
      {:error, reason} ->
        {:error, reason}
    end
  end
  defp odb_flush(%__MODULE__{callback: nil} = handle) do
    case apply_pack(handle) do
      {:ok, _oids} -> apply_cmds(handle)
      {:error, reason} -> {:error, reason}
    end
  end

  defp odb_object_match?({type, _oid}, type), do: true
  defp odb_object_match?(_line, _type), do: false

  defp odb_object_hash({type, data}) do
    case GitRekt.Git.odb_object_hash(type, data) do
      {:ok, oid} -> oid
      {:error, reason} -> raise reason
    end
  end

  defp report_status(%__MODULE__{caps: caps, cmds: cmds}) do
    if "report-status" in caps,
      do: List.flatten(["unpack ok", Enum.map(cmds, &"ok #{elem(&1, :erlang.tuple_size(&1)-1)}"), :flush]),
    else: []
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
  defp parse_caps([first_ref|refs]) do
    case String.split(first_ref, "\0", parts: 2) do
      [first_ref] -> {[], [first_ref|refs]}
      [first_ref, caps] -> {String.split(caps, " ", trim: true), [first_ref|refs]}
    end
  end

  defp apply_pack_obj(agent, odb, {:delta_reference, {base_oid, _base_obj_size, _result_obj_size, _cmds} = delta_ref}, mode) do
    {:ok, {obj_type, obj_data}} = GitAgent.odb_read(agent, odb, base_oid)
    apply_pack_obj(agent, odb, resolve_delta_object({obj_type, obj_data}, delta_ref), mode)
  end

  defp apply_pack_obj(agent, odb, {obj_type, obj_data}, :write) do
    case GitAgent.odb_write(agent, odb, obj_data, obj_type) do
      {:ok, oid} -> oid
      {:error, reason} -> raise ArgumentError, message: reason
    end
  end

  defp apply_pack_obj(agent, odb, obj, :write_dump) do
    {apply_pack_obj(agent, odb, obj, :write), obj}
  end

  defp apply_pack_obj(_agent, _odb, {obj_type, obj_data}, mode) when mode in [:write_pack, :commit_pack] do
    case Git.odb_object_hash(obj_type, obj_data) do
      {:ok, oid} -> oid
      {:error, reason} -> raise ArgumentError, message: reason
    end
  end

  defp apply_pack_obj(agent, odb, obj, mode) when mode in [:write_pack_dump, :commit_pack_dump] do
    {apply_pack_obj(agent, odb, obj, :write_pack), obj}
  end

  defp batch_resolve_objects(objs, delta_refs) do
    {delta_objs, delta_refs} = batch_resolve_delta_objects(objs, delta_refs)
    objs = Map.merge(objs, delta_objs) # TODO
    delta_refs = Enum.reverse(delta_refs)
    cond do
      Enum.empty?(delta_refs) ->
        {objs, []}
      Enum.empty?(delta_objs) ->
        {objs, delta_refs}
      true ->
        batch_resolve_objects(objs, delta_refs)
    end
  end

  defp batch_resolve_delta_objects(objs, delta_refs) do
    Enum.reduce(delta_refs, {%{}, []}, fn {base_oid, _, _, _} = delta_ref, {one, two} ->
      if obj = Map.get(objs, base_oid) do
        new_obj = resolve_delta_object(obj, delta_ref)
        {Map.put(one, odb_object_hash(new_obj), new_obj), two}
      else
        {one, [delta_ref|two]}
      end
    end)
  end

  defp resolve_delta_object({obj_type, obj_data}, {_base_oid, base_obj_size, result_obj_size, cmds}) do
    if base_obj_size == byte_size(obj_data) do
      new_data = resolve_delta_chain(obj_data, "", cmds)
      if result_obj_size == byte_size(new_data),
        do: {obj_type, new_data},
      else: raise "invalid result PACK object size (#{result_obj_size} != #{byte_size(new_data)})"
    end ||  raise "invalid base PACK object size (#{base_obj_size} != #{byte_size(obj_data)})"
  end

  defp resolve_delta_chain(_source, target, []), do: target
  defp resolve_delta_chain(source, target, [{:insert, chunk}|cmds]) do
    resolve_delta_chain(source, target <> chunk, cmds)
  end

  defp resolve_delta_chain(source, target, [{:copy, {offset, size}}|cmds]) do
    resolve_delta_chain(source, target <> binary_part(source, offset, size), cmds)
  end
end
