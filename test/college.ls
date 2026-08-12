# Dual enrollment: the partner college merge, the AP-over-college rule,
# college summer sessions, and the advisory hint.

assert = require 'assert'
{ levels, exams, loadYaml, check, freshProfile, cloneSchool, planCourseIds } = require './helpers'
{ buildModel } = require '../engine/dag'
{ search } = require '../engine/search'
{ hints } = require '../engine/hints'

college = loadYaml ['test', 'fixtures', 'tiny-college.yaml']
COLLEGES = { 'test/tiny-college': college }

withPartner = (minGrade, cap) ->
  seq = cloneSchool!
  seq.dual_enrollment = { partners: [{ college: 'test/tiny-college', min_grade_level: minGrade, max_courses_per_term: cap }] }
  seq

check 'college courses merge only with the opt-in, approved only', ->
  seq = withPartner 11, 2
  base = buildModel seq, freshProfile!, levels, exams, COLLEGES
  assert not base.courses['MCALC1']?, 'merged without the dualEnrollment opt-in'
  profile = freshProfile!
  profile.dualEnrollment = true
  merged = buildModel seq, profile, levels, exams, COLLEGES
  assert merged.courses['MCALC1']?, 'approved college course missing'
  assert not merged.courses['MDEV1']?, 'unapproved college course merged'
  assert.deepEqual merged.courses['MCALC1'].grade_levels, [11, 12], 'partner minimum grade not applied'
  assert 'summer' in merged.courses['MCALC1'].offered_terms, 'college summer session not offered'
  assert.strictEqual merged.courses['MCALC1'].grad_credits, 1.0, 'HS graduation credit not fixed at 1.0'

check 'the AP course beats its college counterpart', ->
  seq = withPartner 11, 2
  profile = freshProfile!
  profile.dualEnrollment = true
  profile.rigor = 1
  model = buildModel seq, profile, levels, exams, COLLEGES
  result = search model, {}
  for state in result.plans
    ids = planCourseIds state
    both = 'MCALC1' in ids and 'APCALCA' in ids
    assert not both, 'AP course and its college counterpart both scheduled'
  best = planCourseIds result.plans[0]
  assert 'APCALCA' in best, 'AP calculus dropped from the best plan'
  assert 'MCALC1' not in best, 'college counterpart chosen over the AP course'

check 'a scheduled college counterpart warns about the AP exam', ->
  seq = withPartner 11, 2
  profile = freshProfile!
  profile.dualEnrollment = true
  profile.avoid = ['APCALCA', 'APCALCB']
  model = buildModel seq, profile, levels, exams, COLLEGES
  result = search model, {}
  best = planCourseIds result.plans[0]
  assert 'MCALC1' in best, 'college calculus not scheduled with the AP course avoided'
  found = false
  for w in result.warnings when w.indexOf('AP exam') >= 0
    found := true
  assert found, "no AP-exam warning in: #{result.warnings.join ' / '}"

# This fixture is adversarial: with 3 periods and one covering path,
# the state that keeps both college courses free for the summer ties
# with siblings that already spent them, and the default beam cannot
# tell those apart before the summer arrives. Beam width is the
# documented search-effort knob; 200 finds the path. Real catalogs
# carry many covering paths and are far less beam-sensitive.
check 'college courses in a college summer pull graduation earlier', ->
  seq = withPartner 9, 2
  profile = freshProfile!
  profile.objective = 'early_grad'
  profile.optionalTerms = ['9:summer', '10:summer']
  base = buildModel seq, profile, levels, exams, COLLEGES
  baseBest = (search base, { beam: 200 }).plans[0]
  de = JSON.parse JSON.stringify profile
  de.dualEnrollment = true
  deBest = (search (buildModel seq, de, levels, exams, COLLEGES), { beam: 200 }).plans[0]
  assert deBest.coveredAt < baseBest.coveredAt, "dual enrollment did not graduate earlier (#{deBest.coveredAt} vs #{baseBest.coveredAt})"

check 'dual enrollment hinted when the catalog runs out of rigor', ->
  seq = withPartner 11, 2
  seq.courses = [c for c in seq.courses when c.level is 'regular']
  profile = freshProfile!
  profile.rigor = 1
  model = buildModel seq, profile, levels, exams, COLLEGES
  result = search model, {}
  advice = hints model, result, {}
  found = false
  for h in advice when h.indexOf('dual enrollment') >= 0
    found := true
  assert found, "no dual-enrollment hint in: #{advice.join ' / '}"
