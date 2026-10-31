require "minitest/autorun"
require "tmpdir"
require "yaml"
require "stringio"
require_relative "../lib/hamster/cli"
require_relative "../lib/hamster/endpoint_generator"
require_relative "../lib/hamster/agent_guidance"

class AgentGuidanceTest < Minitest::Test
  def app
    Dir.mktmpdir do |root|
      Dir.chdir(root) { Hamster::Generator.create("AgentApp") }
      yield File.join(root, "agent_app")
    end
  end

  def test_skills_metadata_and_installation_preserves_customization
    app do |root|
      %w[hamster-endpoint hamster-database].each do |skill|
        path = ".agents/skills/#{skill}/SKILL.md"
        text = File.read(File.join(root, path))
        metadata = YAML.safe_load(text.split("---", 3)[1])
        assert_equal skill, metadata.fetch("name")
        refute_empty metadata.fetch("description")
      end
      assert Hamster::AgentGuidance.install(root)
      agents = File.join(root, "AGENTS.md")
      File.write(agents, "custom instructions\n")
      before = Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select { |f| File.file?(File.join(root, f)) }.to_h { |f| [f, File.binread(File.join(root, f))] }
      refute Hamster::AgentGuidance.install(root, dry_run: true)
      after = before.keys.to_h { |f| [f, File.binread(File.join(root, f))] }
      assert_equal before, after
      refute Hamster::AgentGuidance.install(root)
      assert_equal "custom instructions\n", File.read(agents)
      missing = File.join(root, ".agents/skills/hamster-endpoint/SKILL.md")
      File.unlink(missing)
      Hamster::AgentGuidance.install(root)
      assert File.file?(missing)
    end
  end

  def test_generator_supported_workflow_and_conflicts
    app do |root|
      Hamster::EndpointGenerator.run(root, %w[endpoint posts/show --method GET --path /posts/:id --name post --view])
      assert_empty Hamster::Build::Manifest.check(root)
      route = File.read(File.join(root, "app/routes/mappings.rb"))
      assert_includes route, 'get "/posts/:id", to: AgentApp::Routes::Posts::Show::Action, as: :post'
      assert File.file?(File.join(root, "app/routes/posts/show/view.html.erb"))
      assert_raises(ArgumentError) { Hamster::EndpointGenerator.run(root, %w[endpoint posts/show]) }
      assert_raises(ArgumentError) { Hamster::EndpointGenerator.run(root, %w[endpoint posts/edit --name post]) }
      assert_raises(ArgumentError) { Hamster::EndpointGenerator.run(root, %w[endpoint posts/create --before unknown]) }
      refute File.exist?(File.join(root, "app/routes/posts/create/action.rb"))
      assert_equal route, File.read(File.join(root, "app/routes/mappings.rb"))
      FileUtils.mkdir_p(File.join(root, "app/concerns"))
      File.write(File.join(root, "app/concerns/auth.rb"), <<~SOURCE)
        module AgentApp
          module Auth
            extend Hamster::Action::Callbacks
            def authenticate
              nil
            end
          end
        end
      SOURCE
      Hamster::EndpointGenerator.run(root, %w[endpoint posts/create --method POST --concern AgentApp::Auth --before authenticate])
      assert_includes File.read(File.join(root, "config/callback_registry.rb")), 'result = authenticate'
      assert_empty Hamster::Build::Manifest.check(root)
      Dir.chdir(root) do
        assert_equal 0, Hamster::CLI.run(%w[generate --help])
        assert_equal 0, Hamster::CLI.run(%w[generate --schema])
        assert_equal 0, Hamster::CLI.run(%w[agents:install --dry-run])
      end
    end
  end
end
