# Runs only against the ephemeral native server started by check --full.
require "net/http"
require "uri"
url = URI(ENV.fetch("HAMSTER_TEST_URL"))
Net::HTTP.start(url.host, url.port, nil, nil, nil, nil) do |http|
  response = http.get("/")
  raise "welcome response" unless response.code == "200" && response.body.include?("Welcome to __APP_NAME__")
  raise "missing route" unless http.get("/missing-native-probe").code == "404"
  raise "wrong method" unless http.post("/", "").code == "405"
  raise "HEAD body" unless http.head("/").body.nil?
end
