require "hamster/data"
class NativeEnabled < Hamster::Table
  table :entries
  column :id, type: :bigint
  column :hidden, type: :text, enabled: false
end
class NativeDisabled < NativeEnabled
  table :entries, enabled: false
end
raise "inheritance" if NativeDisabled.enabled?
raise "column flag" if NativeEnabled.columns[:hidden][:enabled]
begin
  NativeDisabled.select(Hamster::SQL.count).compile
  raise "query allowed"
rescue Hamster::Read::DisabledTableError
  puts "DISABLED_TABLE_OK"
end
begin
  NativeEnabled.select(:hidden).compile
  raise "column allowed"
rescue Hamster::Read::DisabledColumnError
  puts "DISABLED_COLUMN_OK"
end
