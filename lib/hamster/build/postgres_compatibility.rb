# frozen_string_literal: true

module Hamster
  module Build
    module PostgresCompatibility
      REVISION = "5ff0188b0e8dffc88337723411ac725ee2659ff7"
      COPIES = [
        'sev = PgDecode.error_field(body, "V")',
        'sev = PgDecode.error_field(body, "S")',
        'tag = PgDecode.command_tag(m.body)'
      ].freeze

      # The pinned driver predates its Spinel string-ownership workarounds.
      # Apply explicit copies after vendoring, before compiling; never patch
      # an unrecognized revision or silently accept a changed source shape.
      def self.apply(root)
        package = File.join(root, "vendor/packages/pg-0.2.0")
        marker = File.join(package, ".spin-sha")
        unless File.file?(marker) && File.read(marker).strip == REVISION
          raise "PostgreSQL compatibility patch requires pg revision #{REVISION}; run bin/hamster setup with the supported lockfile"
        end
        path = File.join(package, "pg/client.rb")
        source = File.read(path)
        patched = source.lines.map do |line|
          statement = line.strip
          replacement = COPIES.find { |original| statement == original || statement == original + ".dup" }
          replacement && statement == replacement ? line.sub(replacement, replacement + ".dup") : line
        end.join
        COPIES.each do |original|
          unless patched.lines.count { |line| line.strip == original + ".dup" } == 1
            raise "PostgreSQL compatibility patch source mismatch: #{original}"
          end
        end
        File.write(path, patched) unless patched == source
      end
    end
  end
end
