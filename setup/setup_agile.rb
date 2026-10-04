# Włącza tablicę Agile w projekcie pilotażu i nadaje uprawnienia rolom.
# Uruchomienie: docker compose exec -T redmine bin/rails runner /setup/setup_agile.rb
project = Project.find_by!(identifier: 'pilotaz-dev')
project.enable_module!(:agile)

{ 'Developer' => %i[view_agile_queries add_agile_queries],
  'Biznes (UAT)' => %i[view_agile_queries],
  'PO / Lead' => %i[view_agile_queries add_agile_queries manage_public_agile_queries] }.each do |name, perms|
  role = Role.find_by!(name: name)
  perms.each { |p| role.add_permission!(p) }
end

puts "OK: moduły = #{project.enabled_module_names.sort.join(', ')}"
Role.givable.each { |r| puts "  #{r.name}: #{(r.permissions.map(&:to_s).grep(/agile/)).join(', ')}" }
