# Testy UAT jako podzadania: typ "Test UAT", statusy, workflow, uprawnienia, filtry.
# Uruchomienie: docker compose exec -T redmine bin/rails runner /setup/setup_uat_tests.rb
# Idempotentny - można uruchamiać ponownie (nie zmienia haseł).
ActiveRecord::Base.transaction do
  # Podzadania nie mogą nadpisywać priorytetu i dat zadania-rodzica
  Setting.parent_issue_priority = 'independent'
  Setting.parent_issue_dates = 'independent'
  Setting.parent_issue_done_ratio = 'derived'

  # Statusy przypadków. "Niezaliczony" jest otwarty, żeby nie liczył się do postępu.
  last = IssueStatus.maximum(:position).to_i
  st = {}
  [['Do testu', false], ['Zaliczony', true], ['Niezaliczony', false]].each_with_index do |(name, closed), i|
    s = IssueStatus.find_or_initialize_by(name: name)
    s.is_closed = closed
    s.position ||= last + i + 1
    s.save!
    st[name] = s
  end

  t = Tracker.find_or_initialize_by(name: 'Test UAT')
  t.default_status = st['Do testu']
  t.is_in_roadmap = false
  t.description = 'Przypadek testowy UAT - podzadanie funkcjonalności'
  t.position ||= Tracker.maximum(:position).to_i + 1
  t.save!

  project = Project.find_by!(identifier: 'pilotaz-dev')
  project.trackers << t unless project.trackers.include?(t)

  uwagi = IssueCustomField.find_by!(name: 'Uwagi z UAT')
  uwagi.trackers << t unless uwagi.trackers.include?(t)

  r_dev = Role.find_by!(name: 'Developer')
  r_biz = Role.find_by!(name: 'Biznes (UAT)')
  r_po  = Role.find_by!(name: 'PO / Lead')
  r_biz.add_permission!(:manage_subtasks)

  WorkflowTransition.where(tracker_id: t.id).delete_all
  flows = {
    # developer może dopisać przypadek i odesłać niezaliczony do ponownego testu
    r_dev => [[nil, 'Do testu'], ['Niezaliczony', 'Do testu']],
    # wynik testu ustawia tylko biznes (i PO)
    r_biz => [[nil, 'Do testu'], ['Do testu', 'Zaliczony'], ['Do testu', 'Niezaliczony'],
              ['Niezaliczony', 'Zaliczony'], ['Zaliczony', 'Niezaliczony'],
              ['Zaliczony', 'Do testu'], ['Niezaliczony', 'Do testu']],
    r_po  => [[nil, 'Do testu']] + st.keys.product(st.keys).reject { |a, b| a == b }
  }
  flows.each do |role, pairs|
    pairs.each do |from, to|
      WorkflowTransition.create!(role: role, tracker: t, old_status_id: from ? st[from].id : 0,
                                 new_status: st[to])
    end
  end

  # Filtry
  admin = User.find_by!(login: 'admin')
  # filtry testów globalne (wszystkie projekty), kolumna projektu dla rozróżnienia
  q = lambda do |name, statuses, columns|
    query = IssueQuery.find_by(name: name) || IssueQuery.new(name: name)
    query.project = nil
    columns = [:project] + columns
    query.user = admin
    query.visibility = Query::VISIBILITY_PUBLIC
    query.filters = { 'tracker_id' => { operator: '=', values: [t.id.to_s] },
                      'status_id' => { operator: '=', values: statuses.map { |s| st[s].id.to_s } } }
    query.column_names = columns
    query.sort_criteria = [%w[parent asc], %w[id asc]]
    query.save!
    query
  end
  q_todo = q.call('Testy UAT do wykonania', ['Do testu', 'Niezaliczony'],
                  %i[parent subject status assigned_to updated_on])
  q.call('Wyniki testów UAT', st.keys, %i[parent subject status assigned_to cf_placeholder updated_on]
           .map { |c| c == :cf_placeholder ? :"cf_#{uwagi.id}" : c })

  # Funkcjonalności w UAT: pokaż postęp testów
  uat = IssueQuery.find_by(name: 'Do testów UAT', project: project)
  if uat
    uat.column_names = %i[tracker status priority subject assigned_to fixed_version done_ratio updated_on]
    uat.save!
  end

  # Moja strona biznesu: testy do wykonania na górze
  project.members.joins(:roles).where(roles: { id: r_biz.id }).includes(:user).each do |m|
    pref = m.user.pref
    layout = pref.my_page_layout.deep_dup
    settings = pref.my_page_settings.deep_dup
    layout['top'] = Array(layout['top']) - ['issuequery__9']
    layout['top'].unshift('issuequery__9')
    settings['issuequery__9'] = { 'query_id' => q_todo.id.to_s }
    pref.my_page_layout = layout
    pref.my_page_settings = settings
    pref.save!
  end

  # Link do środowiska UAT: widoczny w przypadkach testowych, obowiązkowy od "Gotowy do UAT"
  link = IssueCustomField.find_by!(name: 'Link do środowiska UAT')
  link.trackers << t unless link.trackers.include?(t)
  link.description = 'Adres aplikacji na środowisku testowym - kopiowany do każdego przypadku testowego'
  link.save!
  work_trackers = project.trackers.where.not(id: t.id).to_a
  WorkflowPermission.where(field_name: link.id.to_s).delete_all
  ['Gotowy do UAT', 'UAT w toku', 'UAT odrzucony', 'UAT zaakceptowany'].each do |sname|
    s = IssueStatus.find_by!(name: sname)
    [r_dev, r_biz, r_po].each do |role|
      work_trackers.each do |tr|
        WorkflowPermission.create!(role: role, tracker: tr, old_status: s,
                                   field_name: link.id.to_s, rule: 'required')
      end
    end
  end

  # Szablon przypadku testowego jako domyślna treść kryteriów nowych zadań
  ac = IssueCustomField.find_by!(name: 'Kryteria akceptacji')
  ac.default_value = UatTests::TEMPLATE
  ac.description = 'Każdy punkt listy = jeden przypadek testowy UAT (Gdzie / Kroki / Dane / Oczekiwane). ' \
                   'Zamień teksty w [nawiasach]; nieuzupełniony szablon blokuje wyjście ze statusu Nowy.'
  ac.save!

  puts "OK: typ #{t.name} (##{t.id}), statusy #{st.keys.join('/')}, " \
       "przejścia: #{WorkflowTransition.where(tracker_id: t.id).count}, " \
       "wtyczka: #{Redmine::Plugin.installed?(:uat_tests) ? 'załadowana' : 'BRAK'}"
end
