require "minitest/autorun"
require_relative "../lib/hamster/cli"
require_relative "../lib/hamster/generators/runner"
require_relative "../lib/hamster/application_graph"
class ApplicationGraphTest < Minitest::Test
  def app
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("GraphApp") } }
      root = File.join(parent, "graph_app")
      capture_io { Hamster::Generators::Runner.run(root, %w[endpoint admin/posts/show --view --path /admin/posts/:id]) }
      yield root
    end
  end
  def test_graph_is_deterministic_and_action_links_route_view_hook_and_test
    app do |root|
      FileUtils.mkdir_p(File.join(root, "app/concerns"))
      File.write(File.join(root, "app/concerns/auth.rb"), "module GraphApp\nmodule Auth\n def authenticate; nil; end\nend\nend\n")
      path = File.join(root, "app/routes/admin/posts/show/action.rb")
      File.write(path, File.read(path).sub("  def call", "  include GraphApp::Auth\n  before_action :authenticate\n  def call"))
      Hamster::Build::Manifest.generate(root)
      one = Hamster::ApplicationGraph.new(root).build.report("action", "admin/posts/show")
      assert one["valid"], one["diagnostics"].inspect
      assert_equal one, Hamster::ApplicationGraph.new(root).build.report("action", "admin/posts/show")
      refute_includes JSON.generate(one), root
      assert one["nodes"].any? { |n| n["kind"] == "view" && n["name"] == "admin/posts/show" }
      assert one["edges"].any? { |e| e["relation"] == "before_action" && e["to"].end_with?("Auth#authenticate") }
      assert one["edges"].any? { |e| e["relation"] == "routes_to" }
      assert one["edges"].any? { |e| e["relation"] == "tests" && e["certainty"] == "inferred" }
      assert one["nodes"].all? { |n| n["path"] && n["line"] > 0 }
    end
  end
  def test_literal_route_namespaces_have_correct_paths_and_independent_names
    app do |root|
      path = File.join(root, "app/routes/mappings.rb")
      source = File.read(path)
      insertion = '      namespace :admin do' + "\n" + '        get "/posts", to: GraphApp::Routes::Admin::Posts::Show::Action, as: :posts' + "\n      end\n" + '      namespace :api do' + "\n" + '        get "/posts", to: GraphApp::Routes::Admin::Posts::Show::Action, as: :posts' + "\n      end\n"
      File.write(path, source.sub("    end\n  end\nend", insertion + "    end\n  end\nend"))
      graph = Hamster::ApplicationGraph.new(root).build.report("routes")
      assert graph["valid"], graph["diagnostics"].inspect
      routes = graph["nodes"].select { |node| node["kind"] == "route" }
      assert routes.any? { |route| route["attributes"]["pattern"] == "/admin/posts" && route["attributes"]["name"] == "admin_posts" }
      assert routes.any? { |route| route["attributes"]["pattern"] == "/api/posts" && route["attributes"]["name"] == "api_posts" }
    end
  end

  def test_disabled_dependencies_missing_views_and_renames
    app do |root|
      FileUtils.mkdir_p(File.join(root, "db/tables"))
      File.write(File.join(root, "db/tables/posts.rb"), <<~SOURCE)
        module GraphApp
          class Posts < Hamster::Table
            table :posts
            column :id, type: :bigint
            column :secret, type: :text, enabled: false
          end
          class Child < Posts; end
          class List < Hamster::Query
            from Child
            field :secret, source: Child[:secret]
          end
        end
      SOURCE
      graph = Hamster::ApplicationGraph.new(root).build.report
      refute graph["valid"]
      assert graph["diagnostics"].any? { |d| d["code"] == "schema.disabled_column" }
      File.unlink(File.join(root, "app/routes/admin/posts/show/view.html.erb"))
      graph = Hamster::ApplicationGraph.new(root).build.report
      assert graph["diagnostics"].any? { |d| d["code"] == "view.missing" }
      source = File.join(root, "app/routes/admin/posts/show/action.rb")
      File.rename(source, source.sub("action.rb", "renamed.rb"))
      graph = Hamster::ApplicationGraph.new(root).build.report
      assert graph["nodes"].any? { |n| n["kind"] == "action" && n["path"].end_with?("renamed.rb") }
    end
  end
end
