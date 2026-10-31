require "hamster/web"
class NativeForm < Hamster::Form
  field :title, required: true, max_length: 10
  field :count, type: :integer
  def title; self[:title]; end
end
valid = NativeForm.new({"title" => "日本語", "count" => "12"})
raise "coercion" unless valid.valid? && valid.title == "日本語" && valid.attributes[:count] == 12
invalid = NativeForm.new({"title" => "<script>this is long</script>"})
raise "validation" if invalid.valid?
form = Hamster::View::Form.new(action: "/posts", csrf_token: "token", values: invalid.values, errors: invalid.errors)
html = Hamster::HTML.join([form.start, form.label(:title), form.text(:title), form.error_summary, form.finish]).to_s
raise "escaping" if html.include?("<script>")
raise "preservation" unless html.include?("&lt;script&gt;")
puts "FORM_NATIVE_OK"
