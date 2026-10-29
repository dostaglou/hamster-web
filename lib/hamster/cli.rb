# frozen_string_literal: true

require_relative "web/version"
require "fileutils"
require "json"
require "tmpdir"
require "open3"
require "shellwords"
require_relative "build/manifest"
require_relative "build/postgres_compatibility"

module Hamster
  module CLI
    def self.run(arguments)
      args = arguments.dup
      command = args.shift
      case command
      when "--version"
        puts Web::VERSION
        0
      when "new"
        raise ArgumentError, "Usage: hamster new AppName" unless args.length == 1
        Generator.create(args.first)
        0
      when nil, "help", "--help", "-h"
        puts "Usage: hamster new AppName | setup | manifest | manifest:check | build | serve | routes | console | db:create | db:migrate | db:validate"
        0
      else
        raise ArgumentError, "Unexpected arguments: #{args.join(' ')}" unless args.empty?
        dispatch(command)
      end
    rescue StandardError, Gem::LoadError => error
      warn error.message
      1
    end

    def self.root
      path = Dir.pwd
      loop do
        return path if File.file?(File.join(path, "config/hamster.json"))
        parent = File.dirname(path)
        raise "No Hamster application found" if parent == path
        path = parent
      end
    end

    def self.require_tool!(executable, instruction)
      paths = executable.include?(File::SEPARATOR) ? [executable] : ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |directory| File.join(directory, executable) }
      return if paths.any? { |path| File.file?(path) && File.executable?(path) }

      raise "Required executable #{executable.inspect} was not found; #{instruction}"
    end

    def self.dispatch(command)
      app_root = root
      metadata = JSON.parse(File.read(File.join(app_root, "config/hamster.json")))
      binary = ENV.fetch("HAMSTER_SERVER_BINARY", File.join(app_root, "bin", "#{metadata.fetch('name')}-server"))
      case command
      when "console", "c", "db:validate"
        adapter = File.join(app_root, "config/commands.rb")
        raise "Missing config/commands.rb; add the command adapter from the current app template" unless File.file?(adapter)
        require adapter
        if command == "db:validate"
          require_relative "schema_validation"
          issues = SchemaValidation.run(ApplicationCommands.database)
          raise issues.join("\n") unless issues.empty?
          puts "Database declarations validated (#{Table.registry.length} tables); no migrations were run."
        else
          require_relative "console"
          Console.run(ApplicationCommands.build)
        end
      when "setup"
        require_tool!("bundle", "install Bundler with gem install bundler")
        require_tool!("spin", "install the supported Spinel toolchain (including spin); see the Hamster README") if File.file?(File.join(app_root, "spin.toml"))
        Dir.chdir(app_root) { raise "Dependency installation failed" unless system("bundle", "install") }
        Dir.chdir(app_root) { raise "Spin dependency vendoring failed" unless system("spin", "vendor") } if File.file?(File.join(app_root, "spin.toml"))
        Build::PostgresCompatibility.apply(app_root) if File.file?(File.join(app_root, "spin.toml"))
      when "db:create", "db:migrate"
        require_tool!("spin", "install the supported Spinel toolchain and run bin/hamster setup")
        output, status = Open3.capture2e("spin", "list", "--json", chdir: app_root)
        raise "Cannot resolve PostgreSQL dependency: #{output}" unless status.success?
        pg = JSON.parse(output).find { |package| package["name"] == "pg" }
        raise "PostgreSQL dependency missing; configure pg in spin.toml and run setup" unless pg
        driver = File.join(app_root, "vendor/packages", "pg-#{pg.fetch('version')}")
        raise "PostgreSQL dependency not vendored; run bin/hamster setup" unless File.file?(File.join(driver, "pg/client.rb"))
        $LOAD_PATH.unshift(driver)
        require_relative "database/postgres"
        configuration = Hamster::Database::Configuration.from_env(app_name: metadata.fetch("name"))
        if command == "db:create"
          created = Hamster::Database::Admin.create!(configuration)
          puts(created ? "Database created: #{configuration.database}" : "Database already exists: #{configuration.database}")
        else
          database = Hamster::Database.new(configuration, migrations_path: File.join(app_root, "db/migrations"))
          begin
            database.migrate!
            puts "Database migrated: #{configuration.database}"
          ensure
            database.shutdown
          end
        end
      when "manifest"
        Build::Manifest.generate(app_root)
      when "manifest:check"
        issues = Build::Manifest.check(app_root)
        raise issues.join("\n") unless issues.empty?
        puts "Manifest check passed"
      when "build"
        compiler = ENV.fetch("SPINEL", "spinel")
        require_tool!(compiler, "install the supported Spinel toolchain or set SPINEL to its compiler path; see the Hamster README")
        require_tool!("spin", "install the supported Spinel toolchain (including spin)") if File.file?(File.join(app_root, "spin.toml"))
        Build::PostgresCompatibility.apply(app_root) if File.file?(File.join(app_root, "spin.toml"))
        Build::Manifest.generate(app_root)
        issues = Build::Manifest.check(app_root)
        raise issues.join("\n") unless issues.empty?
        spinner = Gem::Specification.find_by_name("spinel-spinner").full_gem_path
        temporary = binary + ".tmp"
        begin
          Dir.chdir(app_root) do
            flags = ["--require-gate", "-I", File.expand_path("..", __dir__), "-I", File.join(spinner, "lib"), "-I", "."]
            if File.file?("spin.toml")
              output, diagnostic, status = Open3.capture3("spin", "flags")
              raise "Spin dependency resolution failed: #{diagnostic}" unless status.success?
              flags.concat(Shellwords.split(output))
            end
            raise "Spinel compilation failed" unless system(compiler, "bin/server", *flags, "-o", temporary)
          end
          File.rename(temporary, binary)
        ensure
          File.delete(temporary) if File.file?(temporary)
        end
        puts "Built #{binary}"
      when "serve", "server", "s"
        raise "Server binary missing; run bin/hamster build" unless File.executable?(binary)
        Dir.chdir(app_root) { exec(binary) }
      when "routes"
        require File.join(app_root, "config/application")
        Hamster::View.route_mapping.routes.each do |route|
          puts [route.method, route.pattern, route.name, route.action.name].join("  ")
        end
      else
        raise ArgumentError, "Unknown command: #{command}"
      end
      0
    end
  end

  module Generator
    def self.create(input)
      unless input.match?(/\A(?:[A-Z][A-Za-z0-9]*|[a-z][a-z0-9]*(?:_[a-z0-9]+)*)\z/)
        raise ArgumentError, "Use a PascalCase or snake_case application name"
      end
      name = input.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2').gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase
      namespace = name.split("_").map(&:capitalize).join
      raise ArgumentError, "Reserved application name" if %w[Hamster Spinner Object Kernel BasicObject Class Module].include?(namespace)
      destination = File.expand_path(name)
      raise ArgumentError, "Destination already exists: #{destination}" if File.exist?(destination) || File.symlink?(destination)
      template = File.expand_path("../../templates/app", __dir__)
      Dir.mktmpdir(".hamster-", File.dirname(destination)) do |container|
        staging = File.join(container, "app")
        FileUtils.mkdir_p(staging)
        Dir.glob("**/*", File::FNM_DOTMATCH, base: template).each do |relative|
          next if [".", ".."].include?(File.basename(relative))
          source = File.join(template, relative)
          target = File.join(staging, relative)
          if File.directory?(source)
            FileUtils.mkdir_p(target)
          else
            File.write(target, File.read(source).gsub("__APP_MODULE__", namespace).gsub("__APP_NAME__", name).gsub("__HAMSTER_VERSION__", Web::VERSION))
          end
        end
        Build::Manifest.generate(staging)
        File.chmod(0755, File.join(staging, "bin/hamster"))
        raise "Destination appeared during generation" if File.exist?(destination)
        File.rename(staging, destination)
      end
      puts "Created #{name}. Next: cd #{name} && bin/hamster setup"
    end
  end
end
