# frozen_string_literal: true
module Hamster
  module CompiledAssets
    def self.paths; {}; end
    def self.types; {}; end
  end
  module Assets
    module_function
    def path(name)
      value = CompiledAssets.paths[name.to_s]
      raise ArgumentError, "Unknown asset #{name}" unless value
      value.to_s
    end
    def response(env)
      path = env.fetch("PATH_INFO", "/")
      return nil unless path.start_with?("/assets/")
      type = CompiledAssets.types[path]
      return Http.response(404, "Asset not found") unless type
      return Http.response(405, "Method not allowed", {"allow" => "GET, HEAD"}) unless %w[GET HEAD].include?(env.fetch("REQUEST_METHOD", "GET"))
      directory = File.join(ENV.fetch("HAMSTER_APP_ROOT", Dir.pwd), "public/assets")
      result = Downloads.file(path.delete_prefix("/assets/"), root: directory, content_type: type, disposition: "inline")
      result[1]["cache-control"] = "public, max-age=31536000, immutable"
      result
    rescue Errno::ENOENT, Errno::ENOTDIR
      Http.response(404, "Asset not found")
    end
  end
end
