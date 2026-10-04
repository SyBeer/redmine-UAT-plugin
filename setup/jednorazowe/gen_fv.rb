# Podgląd parsowania + generowanie przypadków dla zadań w UAT, które ich nie mają.
admin = User.find_by!(login: 'admin')
Issue.joins(:status).where(issue_statuses: { name: UatTests::READY }).where.not(tracker: UatTests.tracker).find_each do |issue|
  next if UatTests.test_children(issue).exists?
  f = UatTests.field(UatTests::CRITERIA_FIELD)
  cases = UatTests.parse_cases(issue.custom_field_value(f))
  puts "##{issue.id} [#{issue.project.name}] #{issue.subject}: #{cases.size} przypadk."
  created = UatTests.generate(issue, admin)
  created.each { |c| puts "   ##{c.id} #{c.subject}" }
  puts "   (brak - sprawdź log)" if created.empty?
end
