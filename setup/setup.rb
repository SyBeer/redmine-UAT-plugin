# Konfiguracja pilotażu Redmine: statusy, workflow z UAT, role, pola, projekt, użytkownicy.
# Uruchomienie: docker compose exec -T redmine bin/rails runner /setup/setup.rb
# Skrypt jest idempotentny - można go odpalić ponownie.
require 'securerandom'

ActiveRecord::Base.transaction do
  # --- Ustawienia ogólne ---
  Setting.app_title = 'Redmine - pilotaż DEV'
  Setting.default_language = 'pl'
  Setting.force_default_language_for_anonymous = '1'
  Setting.rest_api_enabled = '1'
  Setting.login_required = '1'
  Setting.self_registration = '0'
  Setting.default_projects_public = '0'
  Setting.text_formatting = 'common_mark'
  Setting.host_name = '192.168.1.4:3001'
  Setting.user_format = 'firstname_lastname'
  Setting.cross_project_subtasks = 'tree'

  # --- Priorytety i aktywności ---
  %w[Niski Normalny Wysoki Pilny].each_with_index do |name, i|
    p = IssuePriority.find_or_initialize_by(name: name)
    p.position = i + 1
    p.is_default = (name == 'Normalny')
    p.save!
  end
  ['Programowanie', 'Analiza', 'Code review', 'Testy UAT'].each_with_index do |name, i|
    a = TimeEntryActivity.find_or_initialize_by(name: name)
    a.position = i + 1
    a.is_default = (i == 0)
    a.save!
  end

  # --- Statusy (kolejność = przepływ) ---
  STATUSES = [
    ['Nowy', false], ['Gotowy', false], ['W realizacji', false], ['Code review', false],
    ['Gotowy do UAT', false], ['UAT w toku', false], ['UAT odrzucony', false],
    ['UAT zaakceptowany', false], ['Zamknięty', true], ['Odrzucony', true]
  ]
  st = {}
  STATUSES.each_with_index do |(name, closed), i|
    s = IssueStatus.find_or_initialize_by(name: name)
    s.is_closed = closed
    s.position = i + 1
    s.save!
    st[name] = s
  end

  # --- Typy zadań ---
  trackers = ['Błąd', 'Funkcjonalność', 'Zadanie'].each_with_index.map do |name, i|
    t = Tracker.find_or_initialize_by(name: name)
    t.default_status = st['Nowy']
    t.position = i + 1
    t.save!
    t
  end

  # --- Role ---
  common = %i[view_issues add_issues add_issue_notes edit_own_issue_notes view_issue_watchers
              add_issue_watchers save_queries view_gantt view_calendar view_wiki_pages
              view_files view_documents view_time_entries view_news]
  dev_perms = common + %i[edit_issues manage_subtasks manage_issue_relations log_time
                          edit_own_time_entries edit_wiki_pages view_changesets browse_repository
                          view_private_notes set_notes_private]
  biz_perms = common + %i[edit_issues]
  po_perms = dev_perms + %i[manage_versions manage_categories set_issues_private add_issue_watchers
                            delete_issue_watchers manage_public_queries edit_issue_notes
                            manage_members view_members delete_wiki_pages protect_wiki_pages
                            manage_wiki rename_wiki_pages add_documents edit_documents manage_files
                            view_all_time_entries edit_time_entries]

  role = lambda do |name, perms, pos|
    r = Role.find_or_initialize_by(name: name)
    r.permissions = perms.uniq
    r.assignable = true
    r.issues_visibility = 'all'
    r.position = pos
    r.save!
    r
  end
  r_dev = role.call('Developer', dev_perms, 1)
  r_biz = role.call('Biznes (UAT)', biz_perms, 2)
  r_po  = role.call('PO / Lead', po_perms, 3)

  # --- Workflow ---
  WorkflowRule.where(role_id: [r_dev.id, r_biz.id, r_po.id]).delete_all

  dev_tr = [
    ['Gotowy', 'W realizacji'], ['W realizacji', 'Code review'], ['Code review', 'W realizacji'],
    ['Code review', 'Gotowy do UAT'], ['UAT odrzucony', 'W realizacji'], ['W realizacji', 'Gotowy']
  ]
  biz_tr = [
    ['Gotowy do UAT', 'UAT w toku'], ['UAT w toku', 'UAT zaakceptowany'],
    ['UAT w toku', 'UAT odrzucony'], ['UAT odrzucony', 'UAT w toku'], ['Nowy', 'Odrzucony']
  ]
  po_tr = st.keys.product(st.keys).reject { |a, b| a == b }

  add_tr = lambda do |r, pairs|
    trackers.each do |t|
      # 0 = tworzenie nowego zadania
      WorkflowTransition.create!(role: r, tracker: t, old_status_id: 0, new_status: st['Nowy'])
      pairs.each do |from, to|
        WorkflowTransition.create!(role: r, tracker: t, old_status: st[from], new_status: st[to])
      end
    end
  end
  add_tr.call(r_dev, dev_tr)
  add_tr.call(r_biz, biz_tr)
  add_tr.call(r_po, po_tr)

  # --- Pola własne ---
  cf = lambda do |name, format, opts = {}|
    f = IssueCustomField.find_or_initialize_by(name: name)
    f.field_format = format
    f.is_for_all = true
    f.visible = true
    f.trackers = trackers
    f.text_formatting = 'full' if format == 'text'
    f.assign_attributes(opts)
    f.save!
    f
  end
  cf_ac  = cf.call('Kryteria akceptacji', 'text', description: 'Given / When / Then - co biznes sprawdza na UAT')
  cf_env = cf.call('Link do środowiska UAT', 'link', url_pattern: '%value%')
  cf_uat = cf.call('Uwagi z UAT', 'text', description: 'Wynik testów biznesowych, co nie działa')

  # Kryteria akceptacji wymagane od statusu "Gotowy" wzwyż (dla wszystkich ról)
  WorkflowPermission.where(field_name: cf_ac.id.to_s).delete_all
  required_from = ['Gotowy', 'W realizacji', 'Code review', 'Gotowy do UAT', 'UAT w toku',
                   'UAT odrzucony', 'UAT zaakceptowany', 'Zamknięty']
  [r_dev, r_biz, r_po].each do |r|
    trackers.each do |t|
      required_from.each do |s|
        WorkflowPermission.create!(role: r, tracker: t, old_status: st[s],
                                   field_name: cf_ac.id.to_s, rule: 'required')
      end
    end
  end

  # --- Projekt ---
  project = Project.find_or_initialize_by(identifier: 'pilotaz-dev')
  project.name = 'Pilotaż DEV'
  project.description = 'Projekt testowy: backlog zespołu DEV + przekazanie do UAT dla biznesu.'
  project.is_public = false
  project.trackers = trackers
  project.save!
  project.enabled_module_names = %w[issue_tracking time_tracking wiki files calendar gantt news]
  project.issue_custom_fields = [cf_ac, cf_env, cf_uat]

  %w[Sprint\ 1 Sprint\ 2 Release\ 1.0].each do |v|
    project.versions.find_or_create_by!(name: v) { |ver| ver.status = 'open' }
  end

  # --- Użytkownicy testowi ---
  creds = []
  admin = User.find_by(login: 'admin')
  admin_pw = SecureRandom.alphanumeric(14)
  admin.password = admin.password_confirmation = admin_pw
  admin.must_change_passwd = true
  admin.language = 'pl'
  admin.save!
  creds << ['admin', admin_pw, 'Administrator']

  users = [
    ['dev1', 'Dev', 'Pierwszy', r_dev], ['dev2', 'Dev', 'Drugi', r_dev], ['dev3', 'Dev', 'Trzeci', r_dev],
    ['po', 'Product', 'Owner', r_po], ['biznes1', 'Tester', 'Biznesowy', r_biz]
  ]
  users.each do |login, first, last, r|
    u = User.find_or_initialize_by(login: login)
    pw = SecureRandom.alphanumeric(12)
    u.firstname = first
    u.lastname = last
    u.mail = "#{login}@example.com"
    u.language = 'pl'
    u.password = u.password_confirmation = pw
    u.must_change_passwd = true
    u.status = User::STATUS_ACTIVE
    u.save!
    m = Member.find_or_initialize_by(project: project, user: u)
    m.roles = [r]
    m.save!
    creds << [login, pw, r.name]
  end

  # --- Zapisane filtry (publiczne w projekcie) ---
  q = lambda do |name, statuses, extra = {}|
    query = IssueQuery.find_or_initialize_by(name: name, project: project)
    query.user = admin
    query.visibility = Query::VISIBILITY_PUBLIC
    query.filters = { 'status_id' => { operator: '=', values: statuses.map { |s| st[s].id.to_s } } }
    query.column_names = %i[tracker status priority subject assigned_to fixed_version updated_on]
    query.sort_criteria = extra[:sort] || [%w[priority desc], %w[id asc]]
    query.save!
  end
  q.call('Backlog', ['Nowy', 'Gotowy'])
  q.call('W toku (DEV)', ['W realizacji', 'Code review', 'UAT odrzucony'])
  q.call('Do testów UAT', ['Gotowy do UAT', 'UAT w toku'])
  q.call('Gotowe do wydania', ['UAT zaakceptowany'])

  File.write('/usr/src/redmine/files/.credentials.tmp',
             creds.map { |c| c.join("\t") }.join("\n") + "\n")
  puts "OK: #{IssueStatus.count} statusów, #{Tracker.count} typy, #{Role.givable.count} role, #{project.members.count} członków"
end
