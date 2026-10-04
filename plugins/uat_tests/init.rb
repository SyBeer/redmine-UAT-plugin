# Testy UAT jako podzadania: generowanie z kryteriów akceptacji, blokada akceptacji
# niezaliczonego UAT, ponowny test po poprawce, ukrycie przypadków na tablicy Agile.
require 'redmine'

Redmine::Plugin.register :uat_tests do
  name 'Testy UAT (pilotaż)'
  author 'pilotaż DEV'
  description 'Przypadki testowe UAT jako podzadania z blokadą akceptacji'
  version '0.5.0'
  requires_redmine version_or_higher: '6.0'
end

module UatTests
  TRACKER = 'Test UAT'
  NEW = 'Nowy'
  READY = 'Gotowy do UAT'
  ACCEPTED = 'UAT zaakceptowany'
  TODO = 'Do testu'
  PASSED = 'Zaliczony'
  FAILED = 'Niezaliczony'
  TEST_STATUSES = [TODO, PASSED, FAILED].freeze
  CRITERIA_FIELD = 'Kryteria akceptacji'
  LINK_FIELD = 'Link do środowiska UAT'
  # przypadek = punkt listy bez wcięcia; wcięte linie należą do niego
  ITEM = /\A\s?(?:[-*+]|\d+[.)])\s+(.*)\z/
  # nagłówek przypadku: cała linia pogrubiona (**AC-006-1**) albo nagłówek Markdown (### ...)
  HEADER = /\A\s?(?:\*\*([^*]+?)\*\*|\#{1,6}\s+(.+?))\s*\z/
  KEYWORDS = /\A(Given|When|Then|Gdzie|Kroki|Dane|Oczekiwane)\b/i
  ID_ONLY = /\A[A-Z]{1,6}-[\d.-]+\z/
  LABEL = /\A(?:[-*+]\s+)?(Gdzie|Kroki|Dane|Oczekiwane|Given|When|Then)\s*:\s*(.*)\z/i
  # nieuzupełnione pola szablonu
  PLACEHOLDER = /\[(nazwa przypadku|menu → ekran|krok \d|dane testowe|oczekiwany wynik)\]/
  TEMPLATE = <<~MD.freeze
    - [nazwa przypadku]
      - Gdzie: [menu → ekran]
      - Kroki:
        1. [krok 1]
        2. [krok 2]
      - Dane: [dane testowe]
      - Oczekiwane: [oczekiwany wynik]
  MD

  def self.tracker
    Tracker.find_by(name: TRACKER)
  end

  def self.field(name)
    IssueCustomField.find_by(name: name)
  end

  # Jeden punkt listy = jeden przypadek; tekst bez listy = jeden przypadek.
  def self.parse_cases(text)
    lines = text.to_s.gsub("\r\n", "\n").split("\n")
    cases = []
    lines.each do |line|
      if (m = line.match(ITEM)) || ((h = line.match(HEADER)) && !(h[1] || h[2]).strip.match?(KEYWORDS))
        cases << { title: m ? m[1] : (h[1] || h[2]).strip, rest: [] }
      elsif cases.any? && line.strip.present?
        cases.last[:rest] << line
      end
    end
    if cases.empty?
      body = lines.map(&:strip).reject(&:blank?)
      cases = [{ title: body.first.to_s, rest: body.drop(1) }] if body.any?
    end
    cases.map do |c|
      title = c[:title].gsub(/\*\*|__|`/, '').strip
      title = title.split(/\s+[—–-]\s+|:\s+/).first if title.length > 60
      title = "#{title}: #{then_of(c[:rest])}" if title.match?(ID_ONLY) && then_of(c[:rest])
      { title: title.truncate(90), body: format_body(c[:title], c[:rest]) }
    end
  end

  # Sam identyfikator (AC-006-1) nic nie mówi testerowi - dokładamy treść "Then".
  def self.then_of(rest)
    line = rest.map(&:strip).find { |l| l.gsub(/\*\*|__/, '').match?(/\AThen\b/i) }
    line && line.gsub(/\*\*|__|`/, '').sub(/\AThen\s*:?\s*/i, '').strip.presence
  end

  # Szablon (Gdzie/Kroki/Dane/Oczekiwane) -> osobne akapity z pogrubionymi etykietami.
  def self.format_body(title, rest)
    return title if rest.empty?

    out = []
    rest.each do |raw|
      line = raw.strip
      if (m = line.match(LABEL))
        out << '' << "**#{m[1].capitalize}:** #{m[2]}".rstrip
      elsif line.match?(/\A\d+[.)]\s+/)
        out << line
      else
        out << line.sub(/\A[-*+]\s+/, '- ')
      end
    end
    "### #{title.gsub(/\*\*|__/, '').strip}\n#{out.join("\n")}"
  end

  def self.test_children(issue)
    t = tracker or return Issue.none
    issue.children.where(tracker_id: t.id)
  end

  def self.link_of(issue)
    f = field(LINK_FIELD)
    f && issue.custom_field_value(f).presence
  end

  def self.generate(issue, user = User.current)
    t = tracker
    return [] if t.nil? || issue.tracker_id == t.id || test_children(issue).exists?

    f = field(CRITERIA_FIELD)
    criteria = f && issue.custom_field_value(f)
    author = user&.logged? ? user : issue.author
    if criteria.blank?
      warn_on(issue, author, 'brak kryteriów akceptacji - uzupełnij je i ponownie oddaj zadanie do UAT.')
      return []
    end

    unless issue.project.trackers.include?(t)
      issue.project.trackers << t
      Rails.logger.info "[uat_tests] włączono typ #{TRACKER} w projekcie #{issue.project.identifier}"
    end
    link_field = field(LINK_FIELD)
    link = link_of(issue)
    # do zamkniętej/zablokowanej wersji nie da się przypisać - przypadek powstaje bez wersji
    version = issue.fixed_version if issue.fixed_version&.open?
    failed = []
    created = parse_cases(criteria).each_with_index.filter_map do |c, i|
      child = Issue.new(project: issue.project, tracker: t, author: author,
                        parent_issue_id: issue.id, fixed_version: version,
                        priority: issue.priority, subject: "TC#{i + 1}: #{c[:title]}",
                        description: "#{c[:body]}\n\n_Wygenerowano z kryteriów akceptacji ##{issue.id}._")
      child.custom_field_values = { link_field.id.to_s => link } if link_field && link
      if child.save
        child
      else
        failed << "TC#{i + 1} (#{c[:title].truncate(40)}): #{child.errors.full_messages.join(', ')}"
        nil
      end
    end
    warn_on(issue, author, failed.map { |f| "\n- #{f}" }.join) if failed.any?
    created
  end

  # Błąd widoczny w historii zadania (nie tylko w logu serwera).
  def self.warn_on(issue, user, reason)
    msg = "⚠️ Nie udało się utworzyć przypadków testowych UAT: #{reason}"
    Rails.logger.warn "[uat_tests] ##{issue.id}: #{msg}"
    Journal.create!(journalized: issue, user: user, notes: msg)
  rescue StandardError => e
    Rails.logger.error "[uat_tests] ##{issue.id}: nie zapisano ostrzeżenia: #{e.message}"
  end

  # Po powrocie do UAT: niezaliczone -> Do testu, aktualny link w każdym przypadku.
  def self.refresh(issue, user = User.current)
    todo = IssueStatus.find_by(name: TODO)
    link_field = field(LINK_FIELD)
    link = link_of(issue)
    actor = user&.logged? ? user : issue.author
    test_children(issue).includes(:status).find_each do |child|
      notes = []
      if todo && child.status.name == FAILED
        child.status = todo
        notes << 'Ponowny test po poprawce (zadanie wróciło do UAT).'
      end
      if link_field && link && child.custom_field_value(link_field) != link
        child.custom_field_values = { link_field.id.to_s => link }
        notes << "Zaktualizowano link do środowiska UAT: #{link}"
      end
      next if notes.empty?

      child.init_journal(actor, notes.join("\n\n"))
      child.save
    end
  end

  module IssuePatch
    def self.prepended(base)
      base.class_eval do
        validate :uat_tests_acceptance_gate
        validate :uat_tests_template_filled
        after_save :uat_tests_on_ready
      end
    end

    private

    def uat_tests_acceptance_gate
      return unless persisted? && status_id_changed? && status&.name == UatTests::ACCEPTED

      pending = UatTests.test_children(self).joins(:status).where.not(issue_statuses: { name: UatTests::PASSED })
      return unless pending.exists?

      errors.add :base, 'Nie można zaakceptować UAT - niezaliczone lub niewykonane testy: ' +
                        pending.map { |i| "##{i.id} (#{i.status.name})" }.join(', ')
    end

    # Szablon kryteriów może zostać nieuzupełniony tylko w statusie "Nowy".
    def uat_tests_template_filled
      return if status.nil? || status.name == UatTests::NEW

      f = UatTests.field(UatTests::CRITERIA_FIELD)
      text = f && custom_field_value(f)
      return unless text.to_s.match?(UatTests::PLACEHOLDER)

      errors.add :base, 'Kryteria akceptacji zawierają nieuzupełniony szablon ' \
                        '(np. [nazwa przypadku], [krok 1]) - uzupełnij albo usuń te linie.'
    end

    def uat_tests_on_ready
      return unless saved_change_to_status_id? && status&.name == UatTests::READY

      if UatTests.test_children(self).exists?
        UatTests.refresh(self)
      else
        UatTests.generate(self)
      end
    end
  end

  # Link do środowiska UAT otwiera się w nowej karcie - w zadaniu, na listach i w tabelach.
  class Hooks < Redmine::Hook::ViewListener
    def view_layouts_base_html_head(_context = {})
      f = UatTests.field(UatTests::LINK_FIELD) or return ''
      javascript_tag(<<~JS)
        (function () {
          var sel = '.cf_#{f.id} a[href]';
          function fix(root) {
            root.querySelectorAll(sel).forEach(function (a) {
              a.target = '_blank';
              a.rel = 'noopener noreferrer';
            });
          }
          document.addEventListener('DOMContentLoaded', function () {
            fix(document);
            new MutationObserver(function (list) {
              list.forEach(function (m) {
                m.addedNodes.forEach(function (n) { if (n.querySelectorAll) fix(n); });
              });
            }).observe(document.body, { childList: true, subtree: true });
          });
        })();
      JS
    end
  end

  # Tablica Agile: przypadki testowe i ich statusy ukryte, chyba że ktoś filtruje po typie zadania.
  module AgileQueryPatch
    def statement
      s = super
      t = UatTests.tracker
      return s if t.nil? || filters&.key?('tracker_id')

      cond = "#{Issue.table_name}.tracker_id <> #{t.id}"
      s.present? ? "(#{s}) AND #{cond}" : cond
    end

    def board_statuses
      list = super
      return list if filters&.key?('tracker_id')

      list.reject { |s| UatTests::TEST_STATUSES.include?(s.name) }
    end
  end
end

# Redmine 6 uruchamia init.rb wtyczek już wewnątrz to_prepare (PluginLoader.load),
# więc łatki dokładamy bezpośrednio. redmine_agile ładuje się wcześniej (kolejność alfabetyczna).
Issue.prepend(UatTests::IssuePatch) unless Issue <= UatTests::IssuePatch
if defined?(AgileQuery) && !(AgileQuery <= UatTests::AgileQueryPatch)
  AgileQuery.prepend(UatTests::AgileQueryPatch)
end
