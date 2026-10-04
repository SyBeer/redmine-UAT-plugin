# Tryb bez SMTP: wyłącza powiadomienia e-mail, ustawia "Moją stronę" z filtrami zamiast maili.
# Uruchomienie: docker compose exec -T redmine bin/rails runner /setup/setup_no_smtp.rb
Setting.notified_events = []
Setting.lost_password = '0'          # reset hasła wymaga maila - robi to admin
Setting.feeds_limit = '50'

project = Project.find_by!(identifier: 'pilotaz-dev')
query = ->(name) { IssueQuery.find_by!(name: name, project: project) }

layouts = {
  'Developer'    => ['W toku (DEV)', 'Backlog'],
  'Biznes (UAT)' => ['Do testów UAT', 'Gotowe do wydania'],
  'PO / Lead'    => ['Do testów UAT', 'W toku (DEV)', 'Backlog']
}

User.active.where(admin: false).find_each do |u|
  u.pref.no_self_notified = true
  u.update_column(:mail_notification, 'none')
  role = project.members.find_by(user_id: u.id)&.roles&.first
  next unless role && layouts[role.name]

  blocks = layouts[role.name].each_with_index.map { |name, i| ["issuequery__#{i + 1}", query.(name)] }
  u.pref.my_page_layout = { 'top' => blocks.map(&:first), 'left' => ['issuesassignedtome'], 'right' => ['activity'] }
  u.pref.my_page_settings = blocks.to_h { |key, q| [key, { 'query_id' => q.id.to_s }] }
  u.pref.save!
  puts "#{u.login}: Moja strona = #{layouts[role.name].join(', ')}"
end
puts "Powiadomienia e-mail: #{Setting.notified_events.empty? ? 'wyłączone' : Setting.notified_events.inspect}"
