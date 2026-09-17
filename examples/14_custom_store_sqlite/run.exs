alias Autonomic.Canonical
alias Autonomic.Dev.{StoreCase, Support}

Support.reset!()
sqlite = System.find_executable("sqlite3")
if is_nil(sqlite) do
  IO.puts("PREREQUISITE NOT PRESENT: sqlite3 is required. Install SQLite, then rerun `mix run`.")
  System.halt(0)
end

path = Path.join(System.tmp_dir!(), "autonomic-example-#{Canonical.id()}.sqlite3")
{:ok, pid} = ExampleSQLiteStore.start_link(path)
episode_id = Canonical.id()
:ok = ExampleSQLiteStore.create_episode(episode_id, 1)
:ok = StoreCase.verify_epoch_fencing!(ExampleSQLiteStore, episode_id)
{:ok, 2} = ExampleSQLiteStore.current_epoch(episode_id)

concurrent_id = Canonical.id()
:ok = ExampleSQLiteStore.create_episode(concurrent_id, 1)
tasks = for n <- 1..2, do: Task.async(fn -> ExampleSQLiteStore.advance_epoch(concurrent_id, %{writer: n}) end)
epochs = tasks |> Enum.map(&Task.await(&1, 2_000)) |> Enum.map(fn {:ok, epoch} -> epoch end) |> Enum.sort()
Support.assert_equal!(epochs, [2, 3], "serialized concurrent epoch writers")
{:ok, 3} = ExampleSQLiteStore.current_epoch(concurrent_id)
Support.assert!(File.exists?(path), "SQLite database must exist")
GenServer.stop(pid)
File.rm(path)
IO.puts("ASSERTION PASSED: SQLite-backed example preserves monotonic epoch advance, lease revocation, and effect staling under a serialized writer")
