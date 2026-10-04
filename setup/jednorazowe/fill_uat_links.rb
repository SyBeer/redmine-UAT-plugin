# Jednorazowo: uzupełnia link do UAT w zadaniach, które weszły do UAT przed wprowadzeniem wymogu.
LINKS = { 'pilotaz-dev' => 'https://uat.example.com',
          'fv-manager'  => 'http://homeassistant.local:8123/app/98009506_fv-manager' }.freeze
uat = IssueStatus.where(name: ['Gotowy do UAT', 'UAT w toku', 'UAT odrzucony', 'UAT zaakceptowany'])
link = IssueCustomField.find_by!(name: UatTests::LINK_FIELD)
admin = User.find_by!(login: 'admin')
test = UatTests.tracker

LINKS.each do |ident, url|
  project = Project.find_by!(identifier: ident)
  project.issues.where(status: uat).where.not(tracker: test).find_each do |issue|
    next if UatTests.link_of(issue).present?
    unless issue.available_custom_fields.include?(link)
      puts "  ##{issue.id}: pole linku niedostępne dla typu #{issue.tracker.name} - pomijam"
      next
    end
    issue.init_journal(admin, 'Uzupełniono link do środowiska UAT (pole stało się obowiązkowe).')
    issue.custom_field_values = { link.id.to_s => url }
    # bez walidacji: część starszych zadań nie ma jeszcze kryteriów akceptacji
    issue.save(validate: false)
    kids = UatTests.test_children(issue).to_a
    kids.each do |child|
      child.init_journal(admin, "Link do środowiska UAT: #{url}")
      child.custom_field_values = { link.id.to_s => url }
      child.save(validate: false)
    end
    puts "  ##{issue.id} [#{project.name}] #{issue.status.name}: #{UatTests.link_of(issue.reload)}" \
         "#{kids.any? ? " (+ #{kids.size} przypadki)" : ''}"
  end
end
