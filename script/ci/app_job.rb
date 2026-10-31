module DeployApp
  class SmokeJob < Hamster::Job
    job "deploy.smoke", version: 1
    def perform(arguments, version:)
      Hamster::Jobs.database.with_connection do |connection|
        connection.execute("INSERT INTO container_probes(id,message) VALUES(2,'native worker job')")
      end
    end
  end
end
