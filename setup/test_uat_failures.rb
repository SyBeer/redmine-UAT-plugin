# Test sytuacji awaryjnych wtyczki uat_tests. Wszystko w transakcji wycofywanej na końcu.
# Uruchomienie: docker compose exec -T redmine bin/rails runner /setup/test_uat_failures.rb
results = []
check = ->(desc, ok, info = nil) { results << ok; puts "#{ok ? '  PASS' : '  FAIL'}  #{desc}#{info && !ok ? "  [#{info}]" : ''}" }

ActiveRecord::Base.transaction do
  User.current = User.find_by!(login: 'admin')
  project = Project.find_by!(identifier: 'pilotaz-dev')
  ready = IssueStatus.find_by!(name: UatTests::READY)
  review = IssueStatus.find_by!(name: 'Code review')
  ac = UatTests.field(UatTests::CRITERIA_FIELD)
  link = UatTests.field(UatTests::LINK_FIELD)
  mk = lambda do |subject, version = nil|
    i = Issue.new(project: project, tracker: Tracker.find_by!(name: 'Funkcjonalność'), author: User.current,
                  subject: subject, status: review, fixed_version: version)
    i.custom_field_values = { ac.id.to_s => "- Przypadek A\n- Przypadek B", link.id.to_s => 'https://uat.example.com' }
    i.save!
    i
  end

  # 1. zamknięta wersja
  v = project.versions.create!(name: 'TMP sprint zamknięty', status: 'open')
  i1 = mk.call('TMP zamknięta wersja', v)
  v.update!(status: 'closed')
  i1.reload.status = ready
  i1.save!
  kids = UatTests.test_children(i1).to_a
  check.call('zamknięta wersja: przypadki powstają mimo to', kids.size == 2, kids.size)
  check.call('zamknięta wersja: przypadki bez wersji', kids.all? { |k| k.fixed_version_id.nil? })
  check.call('zamknięta wersja: brak ostrzeżenia w zadaniu', i1.journals.where('notes LIKE ?', '%⚠️%').none?)

  # 2. błąd zapisu przypadku -> ostrzeżenie w historii zadania
  IssueCustomField.create!(name: 'TMP wymagane', field_format: 'string', is_required: true,
                           is_for_all: true, trackers: [UatTests.tracker])
  i2 = mk.call('TMP błąd zapisu')
  i2.reload.status = ready
  i2.save!
  note = i2.journals.reload.map(&:notes).find { |n| n.to_s.include?('⚠️') }
  check.call('błąd: zadanie i tak przechodzi do Gotowy do UAT', i2.reload.status == ready)
  check.call('błąd: ostrzeżenie widoczne w historii zadania', note.present?)
  check.call('błąd: ostrzeżenie podaje przyczynę i przypadek', note.to_s.downcase.include?('tmp wymagane') && note.to_s.include?('TC1'), note)
  puts "\n  Treść ostrzeżenia:\n  #{note.to_s.gsub("\n", "\n  ")}\n"

  raise ActiveRecord::Rollback
end
puts "\nWynik: #{results.count(true)}/#{results.size} (zmiany wycofane: #{Version.where(name: 'TMP sprint zamknięty').none? && IssueCustomField.where(name: 'TMP wymagane').none? ? 'tak' : 'NIE'})"
