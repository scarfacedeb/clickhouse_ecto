Logger.configure(level: :info)

ExUnit.start(
  exclude: [
    :array_type,
    :map_type,
    :uses_usec,
    :uses_msec,
    :modify_foreign_key_on_update,
    :create_index_if_not_exists,
    :not_supported_by_sql_server,
    :upsert,
    :upsert_all,
    :identity_insert,
    :update,
    :update_all,
    :delete,
    :delete_all,
    :escaping,
    :decimal_type
  ]
)

# Configure Ecto for support and tests
Application.put_env(:ecto, :primary_key_type, :id)
Application.put_env(:ecto, :lock_for_update, "FOR UPDATE")

# Load support files
Code.require_file("./support/repo.exs", __DIR__)
Code.require_file("./support/schemas.exs", __DIR__)
Code.require_file("./support/migration.exs", __DIR__)

pool =
  case System.get_env("ECTO_POOL") || "poolboy" do
    "poolboy" -> DBConnection.Poolboy
    "sbroker" -> DBConnection.Sojourn
  end


#
# Basic test repo

alias Ecto.Integration.TestRepo

Application.put_env(
  :ecto,
  TestRepo,
  adapter: ClickhouseEcto,
  pool: Ecto.Adapters.SQL.Sandbox,
  ownership_pool: pool,
  database: "clickhouse_ecto_integration_test",
  hostname: System.get_env("CLICKHOUSE_HOST") || "localhost",
  username: System.get_env("CLICKHOUSE_USER") || "default",
  password: System.get_env("CLICKHOUSE_PASS") || "",
  port: System.get_env("CLICKHOUSE_PORT") || "8123"
)

defmodule Ecto.Integration.TestRepo do
  use Ecto.Integration.Repo, otp_app: :ecto
end


#
# Pool repo for transaction and lock tests

alias Ecto.Integration.PoolRepo

Application.put_env(
  :ecto,
  PoolRepo,
  adapter: ClickhouseEcto,
  pool: pool,
  pool_size: 10,
  max_restarts: 20,
  max_seconds: 10,
  database: "clickhouse_ecto_integration_test",
  hostname: System.get_env("CLICKHOUSE_HOST") || "localhost",
  username: System.get_env("CLICKHOUSE_USER") || "default",
  password: System.get_env("CLICKHOUSE_PASS") || "",
  port: System.get_env("CLICKHOUSE_PORT") || "8123"
)

defmodule Ecto.Integration.PoolRepo do
  use Ecto.Integration.Repo, otp_app: :ecto

  def create_prefix(prefix) do
    "create schema #{prefix}"
  end

  def drop_prefix(prefix) do
    "drop schema #{prefix}"
  end
end


#
# Setup

defmodule Ecto.Integration.Case do
  use ExUnit.CaseTemplate

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

    # Clear tables
    opts = TestRepo.config()
    ~w{posts} |> Enum.each(fn table ->
      {:ok, _} = ClickhouseEcto.Storage.run_query("DROP TABLE IF EXISTS #{table}_new", opts)
      {:ok, _} = ClickhouseEcto.Storage.run_query("CREATE TABLE #{table}_new AS #{table}", opts)
      {:ok, _} = ClickhouseEcto.Storage.run_query("DROP TABLE #{table}", opts)
      {:ok, _} = ClickhouseEcto.Storage.run_query("RENAME TABLE #{table}_new TO #{table}", opts)
    end)
  end
end

{:ok, _} = ClickhouseEcto.ensure_all_started(TestRepo, :temporary)

# Load up the repository, start it, and run migrations
_ = ClickhouseEcto.storage_down(TestRepo.config())
:ok = ClickhouseEcto.storage_up(TestRepo.config())

{:ok, _pid} = TestRepo.start_link()
{:ok, _pid} = PoolRepo.start_link()

:ok = Ecto.Migrator.up(TestRepo, 0, Ecto.Integration.Migration, log: false)
Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
Process.flag(:trap_exit, true)
