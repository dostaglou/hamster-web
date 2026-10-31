require "hamster/jobs/worker"
class QueueProbeJob < Hamster::Job
  job "queue.probe", version: 2, accepts: [1]
  def perform(arguments, version:)
    raise "request connection leaked" if Thread.current[:hamster_record_connection]
    key = arguments.fetch("key")
    mode = arguments.fetch("mode", "normal")
    starts = Hamster::Jobs.database.with_connection do |connection|
      connection.execute("INSERT INTO job_probe_starts(id,starts) VALUES($1,1) ON CONFLICT(id) DO UPDATE SET starts=job_probe_starts.starts+1 RETURNING starts", [key]).hashes.first["starts"].to_i
    end
    raise ArgumentError, "private job content" if mode == "fail" || (mode == "retry" && starts == 1)
    sleep 10 if mode == "crash" && starts == 1
    sleep 2.2 if mode == "slow"
    sleep 0.35 if mode == "graceful"
    if mode == "cancel"
      100.times do
        return if Hamster::Jobs.cancelled?
        sleep 0.02
      end
      raise "cancellation not delivered"
    end
    total = 0
    100000.times { |n| total += n } if mode == "cpu"
    Hamster::Jobs.database.with_connection do |connection|
      connection.execute("INSERT INTO job_probe_results(id,total,version) VALUES($1,$2,$3)", [key, total, version])
    end
  end
end
