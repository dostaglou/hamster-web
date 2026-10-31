require "active_job"
class PortabilityProbe < ActiveJob::Base
  self.queue_adapter = :inline
  def perform(value)
    puts "ACTIVE_JOB_PROBE #{value}"
  end
end
PortabilityProbe.perform_now("now")
PortabilityProbe.perform_later("later")
PortabilityProbe.deserialize(PortabilityProbe.new("serialized").serialize).perform_now
