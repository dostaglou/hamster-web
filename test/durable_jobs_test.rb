require "minitest/autorun"
require "yaml"
require_relative "../lib/hamster/cli"
require_relative "../lib/hamster/generators/runner"
require_relative "../lib/hamster/jobs/worker"
class DurableJobsTest < Minitest::Test
  class NoDatabase
    def with_connection; raise "invalid input reached database"; end
  end
  def test_invalid_queue_configuration_fails_before_connecting
    queue = Hamster::Jobs::PostgresQueue.new(database: NoDatabase.new)
    assert_raises(ArgumentError) { Hamster::Jobs::PostgresQueue.new(database: NoDatabase.new, queue: "../bad") }
    assert_raises(ArgumentError) { Hamster::Jobs::PostgresQueue.new(database: NoDatabase.new, lease_seconds: 0) }
    assert_raises(ArgumentError) { Hamster::Jobs::Worker.new(queue, threads: 0) }
    assert_raises(ArgumentError) { Hamster::Jobs::Worker.new(queue, queues: []) }
    assert_raises(ArgumentError) { Hamster::Jobs::Worker.new(queue, queues: ["bad queue"]) }
    assert_raises(Hamster::Jobs::PayloadError) { queue.enqueue("invalid") }
  end
  def test_generated_queue_and_worker_are_separate_from_http_and_checked
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("WorkerApp") } }
      root = File.join(parent, "worker_app")
      before = Dir.glob("db/migrations/*", base: root)
      capture_io { Hamster::Generators::Runner.run(root, %w[job_queue queue --timestamp 20261101000000 --dry-run]) }
      assert_equal before, Dir.glob("db/migrations/*", base: root)
      capture_io do
        Hamster::Generators::Runner.run(root, %w[job_queue queue --timestamp 20261101000000])
        Hamster::Generators::Runner.run(root, %w[job deliver])
      end
      assert_empty Hamster::Build::Manifest.check(root)
      registry = File.read(File.join(root, "config/job_registry.rb"))
      assert_includes registry, "WorkerApp::DeliverJob.new.perform"
      worker = File.read(File.join(root, "bin/worker"))
      refute_includes worker, "Spinner"
      assert_includes worker, "JOB_DATABASE_POOL_SIZE"
      docker = File.read(File.join(root, "Dockerfile"))
      assert_includes docker, "AS worker-builder"
      assert_includes docker, 'ENTRYPOINT ["/app/bin/worker_app-worker"]'
      assert docker.rindex("AS runtime") > docker.index("AS worker\n")
      deployment = YAML.safe_load(File.read(File.join(root, "config/deploy.worker.yml.example")))
      assert_equal "worker", deployment["builder"]["target"]
      assert_equal false, deployment["servers"]["workers"]["proxy"]
    end
  end
end
