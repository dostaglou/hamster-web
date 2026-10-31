require "hamster/database/postgres"
require "hamster/jobs/worker"
require_relative "queue_jobs"
config = Hamster::Database::Configuration.from_env
Hamster::Jobs.database = Hamster::Database.new(config, migrations_path: ENV.fetch("HAMSTER_TEST_MIGRATIONS"))
begin
  queue = Hamster::Jobs::PostgresQueue.new(database: Hamster::Jobs.database,
    lease_seconds: ENV.fetch("JOB_LEASE_SECONDS", "2").to_f, retry_base_seconds: 0.02)
  queue.verify!
  worker = Hamster::Jobs::Worker.new(queue, threads: 2, drain_timeout: 1)
  if ARGV.length == 2 && ARGV[0] == "--enqueue"
    Hamster::Jobs.configure(adapter: queue)
    puts QueueProbeJob.perform_later({"key" => ARGV[1]})
  elsif ARGV == ["--once"]
    worker.run_once
  else
    exit(worker.run ? 0 : 1)
  end
ensure
  Hamster::Jobs.database.shutdown
end
