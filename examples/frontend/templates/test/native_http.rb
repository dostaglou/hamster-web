require "net/http"
require "uri"
require "open3"
require "tmpdir"
url = URI(ENV.fetch("HAMSTER_TEST_URL"))
Net::HTTP.start(url.host, url.port, nil, nil, nil, nil) do |http|
  page = http.get("/posts")
  raise "index" unless page.code == "200"
  token = page.body[/name="csrf_token" value="([^"]+)"/, 1]
  raise "missing csrf" unless token
  headers = {"Content-Type" => "application/x-www-form-urlencoded", "Origin" => url.to_s}
  raise "csrf rejection" unless http.post("/posts", URI.encode_www_form(title: "No token"), headers).code == "403"
  invalid = http.post("/posts", URI.encode_www_form(title: "<script>" * 20, csrf_token: token), headers)
  raise "validation" unless invalid.code == "422" && !invalid.body.include?("<script><script>") && invalid.body.include?("&lt;script&gt;")
  created = http.post("/posts", URI.encode_www_form(title: "No JS created", csrf_token: token), headers)
  raise "no-js create" unless created.code == "303" && http.get("/posts").body.include?("No JS created")
  edit = http.get("/posts/1/edit")
  raise "edit" unless edit.code == "200"
  updated = http.post("/posts/1", URI.encode_www_form(title: "No JS updated", csrf_token: token, _method: "PATCH"), headers)
  raise "no-js update" unless updated.code == "303" && http.get("/posts").body.include?("No JS updated")
  removed = http.post("/posts/1", URI.encode_www_form(csrf_token: token, _method: "DELETE"), headers)
  raise "no-js destroy" unless removed.code == "303" && !http.get("/posts").body.include?("No JS updated")
  css = page.body[/href="(\/assets\/[^"]+\.css)"/, 1]
  asset = http.get(css)
  raise "asset delivery" unless asset.code == "200" && asset["cache-control"].include?("immutable") && asset["x-content-type-options"] == "nosniff"
end
if ENV["HAMSTER_BROWSER_BINARY"]
  output, status = Open3.capture2e("node", "test/browser_smoke.mjs", "#{url}/posts?browser_probe=1")
  raise "Stimulus/Turbo CRUD browser check failed:\n#{output}" unless status.success?
end
puts "FRONTEND_NATIVE_HTTP_OK"
