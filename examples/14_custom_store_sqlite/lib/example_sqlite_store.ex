defmodule ExampleSQLiteStore do
  @moduledoc "SQLite-backed reference for the public Autonomic.Store fencing callbacks. Example only."
  @behaviour Autonomic.Store
  use GenServer

  alias Autonomic.Canonical

  def start_link(path), do: GenServer.start_link(__MODULE__, path, name: __MODULE__)
  def create_episode(id, epoch \\ 1), do: GenServer.call(__MODULE__, {:create_episode, id, epoch})
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def current_epoch(id), do: GenServer.call(__MODULE__, {:current_epoch, id})
  @impl true
  def advance_epoch(id, metadata), do: GenServer.call(__MODULE__, {:advance_epoch, id, metadata})
  @impl true
  def put_lease(lease), do: GenServer.call(__MODULE__, {:put, "lease", lease.id, lease})
  @impl true
  def fetch_lease(id), do: GenServer.call(__MODULE__, {:fetch, "lease", id})
  @impl true
  def put_effect(effect), do: GenServer.call(__MODULE__, {:put, "effect", effect.id, effect})
  @impl true
  def fetch_effect(id), do: GenServer.call(__MODULE__, {:fetch, "effect", id})
  @impl true
  def append_event(episode_id, kind, payload),
    do: GenServer.call(__MODULE__, {:append_event, episode_id, kind, payload})

  @impl true
  def init(path) do
    sqlite =
      System.find_executable("sqlite3") || raise "sqlite3 executable is required for this example"

    File.rm(path)
    File.mkdir_p!(Path.dirname(path))

    :ok =
      exec(
        sqlite,
        path,
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE episodes(id TEXT PRIMARY KEY, epoch INTEGER NOT NULL); CREATE TABLE objects(kind TEXT NOT NULL, id TEXT NOT NULL, blob TEXT NOT NULL, PRIMARY KEY(kind,id)); CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT, episode_id TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL);"
      )

    {:ok, %{sqlite: sqlite, path: path}}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ok =
      exec(
        state.sqlite,
        state.path,
        "DELETE FROM events; DELETE FROM objects; DELETE FROM episodes;"
      )

    {:reply, :ok, state}
  end

  def handle_call({:create_episode, id, epoch}, _from, state) do
    sql = "INSERT INTO episodes(id,epoch) VALUES(#{sql_quote(id)},#{epoch});"
    {:reply, exec(state.sqlite, state.path, sql), state}
  end

  def handle_call({:current_epoch, id}, _from, state) do
    case query(state, "SELECT epoch FROM episodes WHERE id=#{sql_quote(id)};") do
      "" -> {:reply, {:error, :episode_not_found}, state}
      value -> {:reply, {:ok, String.to_integer(value)}, state}
    end
  end

  def handle_call({:put, kind, id, term}, _from, state) do
    blob = encode(term)

    sql =
      "INSERT OR REPLACE INTO objects(kind,id,blob) VALUES(#{sql_quote(kind)},#{sql_quote(id)},#{sql_quote(blob)});"

    {:reply, exec(state.sqlite, state.path, sql), state}
  end

  def handle_call({:fetch, kind, id}, _from, state) do
    case query(
           state,
           "SELECT blob FROM objects WHERE kind=#{sql_quote(kind)} AND id=#{sql_quote(id)};"
         ) do
      "" -> {:reply, :not_found, state}
      blob -> {:reply, {:ok, decode(blob)}, state}
    end
  end

  def handle_call({:advance_epoch, id, metadata}, _from, state) do
    with epoch_text when epoch_text != "" <-
           query(state, "SELECT epoch FROM episodes WHERE id=#{sql_quote(id)};") do
      old_epoch = String.to_integer(epoch_text)
      new_epoch = old_epoch + 1
      now = Canonical.now()

      leases =
        list_objects(state, "lease")
        |> Enum.map(fn {key, lease} ->
          if lease.episode_id == id and lease.epoch < new_epoch and is_nil(lease.revoked_at),
            do: {key, %{lease | revoked_at: now}},
            else: {key, lease}
        end)

      effects =
        list_objects(state, "effect")
        |> Enum.map(fn {key, effect} ->
          if effect.episode_id == id and effect.epoch < new_epoch and
               effect.state in [:proposed, :prepared, :evaluating, :ready],
             do: {key, %{effect | state: :stale}},
             else: {key, effect}
        end)

      rewrites =
        Enum.map(leases, fn {key, value} -> upsert_sql("lease", key, value) end) ++
          Enum.map(effects, fn {key, value} -> upsert_sql("effect", key, value) end)

      event = Canonical.json(%{old_epoch: old_epoch, new_epoch: new_epoch, metadata: metadata})

      sql =
        [
          "BEGIN IMMEDIATE;",
          "UPDATE episodes SET epoch=#{new_epoch} WHERE id=#{sql_quote(id)};",
          rewrites,
          "INSERT INTO events(episode_id,kind,payload) VALUES(#{sql_quote(id)},'epoch_advanced',#{sql_quote(event)});",
          "COMMIT;"
        ]
        |> List.flatten()
        |> Enum.join("\n")

      :ok = exec(state.sqlite, state.path, sql)
      {:reply, {:ok, new_epoch}, state}
    else
      _ -> {:reply, {:error, :episode_not_found}, state}
    end
  end

  def handle_call({:append_event, episode_id, kind, payload}, _from, state) do
    json = Canonical.json(payload)

    :ok =
      exec(
        state.sqlite,
        state.path,
        "INSERT INTO events(episode_id,kind,payload) VALUES(#{sql_quote(episode_id)},#{sql_quote(to_string(kind))},#{sql_quote(json)});"
      )

    seq = query(state, "SELECT COALESCE(MAX(seq),0) FROM events;") |> String.to_integer()
    {:reply, {:ok, seq}, state}
  end

  defp list_objects(state, kind) do
    query(state, "SELECT id || char(9) || blob FROM objects WHERE kind=#{sql_quote(kind)};")
    |> String.split("\n", trim: true)
    |> Enum.map(fn row ->
      [id, blob] = String.split(row, "\t", parts: 2)
      {id, decode(blob)}
    end)
  end

  defp upsert_sql(kind, id, term),
    do:
      "INSERT OR REPLACE INTO objects(kind,id,blob) VALUES(#{sql_quote(kind)},#{sql_quote(id)},#{sql_quote(encode(term))});"

  defp encode(term), do: term |> :erlang.term_to_binary([:compressed]) |> Base.encode64()
  defp decode(text), do: text |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  defp sql_quote(value), do: "'" <> (to_string(value) |> String.replace("'", "''")) <> "'"

  defp exec(sqlite, path, sql) do
    case System.cmd(sqlite, ["-batch", path, sql], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise "sqlite3 failed (#{status}): #{out}"
    end
  end

  defp query(state, sql) do
    case System.cmd(state.sqlite, ["-batch", "-noheader", state.path, sql],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "sqlite3 query failed (#{status}): #{out}"
    end
  end
end
