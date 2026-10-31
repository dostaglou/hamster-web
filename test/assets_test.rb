require "minitest/autorun"
require_relative "../lib/hamster/cli"
require_relative "../lib/hamster/generators/runner"
require_relative "../lib/hamster/testing"
class AssetsTest < Minitest::Test
  def test_assets_are_deterministic_rewrite_imports_and_reject_missing_dependencies
    Dir.mktmpdir do |parent|
      capture_io { Dir.chdir(parent) { Hamster::Generator.create("AssetApp") } }
      root = File.join(parent, "asset_app")
      first = Hamster::Build::Assets.outputs(root)
      assert_equal first, Hamster::Build::Assets.outputs(root)
      manifest = JSON.parse(first.fetch("public/assets/manifest.json")).fetch("assets")
      js = first.fetch("public" + manifest.fetch("application.js"))
      assert_includes js, manifest.fetch("vendor/turbo.js")
      assert_includes js, manifest.fetch("controllers.js")
      capture_io { Hamster::Generators::Runner.run(root, %w[stimulus nested/greeting]) }
      updated = Hamster::Build::Assets.outputs(root)
      map = JSON.parse(updated.fetch("public/assets/manifest.json")).fetch("assets")
      refute_equal manifest["application.js"], map["application.js"]
      assert_includes updated.fetch("public" + map["controllers.js"]), 'nested--greeting'
      assert_empty Hamster::Build::Manifest.check(root)
      File.write(File.join(root, "app/assets/broken.js"), 'import "./missing.js";')
      assert_raises(ArgumentError) { Hamster::Build::Assets.outputs(root) }
    end
  end
  def test_compiled_components_require_explicit_locals_and_safe_inputs
    sources = {"components/card" => {path: "app/views/components/card.html.erb", source: '<%# locals: content %><section><%= content %></section>'},
               "page" => {path: "app/views/page.html.erb", source: '<%= render "components/card", locals: {content: "<bad>"} %>'}}
    compiled = Hamster::ViewCompiler.compile(sources)
    assert_includes compiled, 'view_components_card'
    sources["page"][:source] = '<%= render "components/card" %>'
    assert_raises(Hamster::View::Error) { Hamster::ViewCompiler.compile(sources) }
  end
end
