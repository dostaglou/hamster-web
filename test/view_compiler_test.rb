# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/hamster/build/manifest"

class ViewCompilerTest < Minitest::Test
  def source(path, body)
    {path: path, source: body}
  end

  def compile(templates)
    Hamster::ViewCompiler.compile(templates)
  end

  def test_compiles_control_flow_partials_and_slots_deterministically
    templates = {
      "page" => source("app/routes/page/view.html.erb", <<~ERB),
        <%# locals: items %>
        <% content_for :head do %><meta name="x" content="ok"><% end %>
        <% if items.empty? %>empty<% else %>
        <% items.each do |item| %><%= render "shared/item", locals: {value: item} %><% end %>
        <% end %>
      ERB
      "shared/item" => source("app/routes/shared/item.html.erb", '<p><%= value %></p>'),
      "layouts/application" => source("app/views/layouts/application.html.erb", '<%= yield :head %><%= yield %><%= title %>')
    }
    generated = compile(templates)
    assert_equal generated, compile(templates)
    assert_includes generated, 'context.slot("head")'
    assert_includes generated, 'Hamster::CompiledViews.render("shared/item", context, {value: item})'
    refute_includes generated, '<%'
  end

  def test_rejects_missing_partials_locals_cycles_and_dynamic_names
    missing = {"page" => source("app/routes/page/view.html.erb", '<%= render "shared/missing", locals: {} %>')}
    assert_includes assert_raises(Hamster::View::Error) { compile(missing) }.message,
      'app/routes/page/view.html.erb:1: missing template shared/missing'

    no_local = {"page" => source("app/routes/page/view.html.erb", '<%= render "shared/card", locals: {} %>'),
      "shared/card" => source("app/routes/shared/card.html.erb", '<%= title %>')}
    assert_includes assert_raises(Hamster::View::Error) { compile(no_local) }.message,
      'app/routes/page/view.html.erb:1: shared/card missing locals: title'

    dynamic = {"page" => source("app/routes/page/view.html.erb", '<%= render name, locals: {} %>')}
    assert_includes assert_raises(Hamster::View::Error) { compile(dynamic) }.message,
      'app/routes/page/view.html.erb:1: render requires a literal template name'

    cycle = {"shared/a" => source("a.erb", '<%= render "shared/b", locals: {} %>'),
      "shared/b" => source("b.erb", '<%= render "shared/a", locals: {} %>')}
    assert_includes assert_raises(Hamster::View::Error) { compile(cycle) }.message,
      'b.erb:1: partial dependency cycle'
  end

  def test_rejects_unsafe_html_positions_and_bad_ruby
    {
      '<script><%= value %></script>' => 'dynamic script or style content',
      '<a onclick="<%= value %>">x</a>' => 'dynamic event or style attribute',
      '<a href=<%= value %>>x</a>' => 'expression must be in text or a quoted attribute',
      '<%= yield %>' => 'yield is only supported in layouts',
      '<% if value %>x' => 'unclosed ERB block'
    }.each do |body, message|
      error = assert_raises(Hamster::View::Error) { compile("page" => source("page.erb", body)) }
      assert_includes error.message, message
    end
  end
end
