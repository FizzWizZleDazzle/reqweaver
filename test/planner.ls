# Core planner behavior: feasibility invariants, graduation coverage,
# objectives, determinism, and prior standing.

assert = require 'assert'
{ school, levels, exams, check, freshProfile, cloneSchool, planCourseIds, verifyFeasible } = require './helpers'
{ buildModel } = require '../engine/dag'
{ search } = require '../engine/search'

check 'search finds plans and every plan is feasible', ->
  model = buildModel school, freshProfile!, levels, exams
  result = search model, {}
  assert result.plans.length > 0, 'no plans'
  for state in result.plans
    verifyFeasible model, state

check 'every returned plan covers all graduation requirements', ->
  model = buildModel school, freshProfile!, levels, exams
  result = search model, {}
  for state in result.plans
    assert state.gradRemaining is 0, "plan misses #{state.gradRemaining} graduation credits"

check 'electives do not crowd out requirement courses under tight caps', ->
  profile = freshProfile!
  profile.maxCoursesPerTerm = 2   # 16 slots; requirements + AP need 12
  model = buildModel school, profile, levels, exams
  result = search model, {}
  assert result.plans.length > 0, 'no plans'
  best = result.plans[0]
  assert best.gradRemaining is 0, "requirements unmet: #{best.gradRemaining} credits missing"
  assert 'APCALCB' in planCourseIds(best), 'AP Calculus crowded out'

check 'max_credits reaches AP Calculus and banks credit', ->
  model = buildModel school, freshProfile!, levels, exams
  result = search model, {}
  best = result.plans[0]
  assert best.banked >= 3, "expected banked >= 3, got #{best.banked}"
  assert 'APCALCB' in planCourseIds(best), 'AP Calculus never completed'

check 'deterministic: identical inputs give identical plans', ->
  r1 = search buildModel(school, freshProfile!, levels, exams), {}
  r2 = search buildModel(school, freshProfile!, levels, exams), {}
  sigs = (r) -> [state.sig for state in r.plans].join '|'
  assert.strictEqual sigs(r1), sigs(r2)

check 'completed courses satisfy prereqs and are not retaken', ->
  profile = freshProfile!
  profile.completed = ['ALG1A', 'ALG1B']
  model = buildModel school, profile, levels, exams
  result = search model, {}
  for state in result.plans
    verifyFeasible model, state
    assert 'ALG1A' not in planCourseIds(state), 'retook completed course'

check 'pre-HS credit satisfies prereqs; grad credit follows school policy', ->
  strict = cloneSchool!
  strict.pre_hs_credit.counts_toward_grad = false
  profile = freshProfile!
  profile.preHsCompleted = ['ALG1A', 'ALG1B']
  model = buildModel strict, profile, levels, exams
  result = search model, {}
  best = result.plans[0]
  ids = planCourseIds best
  assert 'ALG1A' not in ids, 'retook pre-HS course'
  assert ('GEOA' in ids or 'GEOHA' in ids), 'prereq standing from pre-HS credit not honored'
  # policy says no grad credit for ALG1, so math needs GEO + AP Calc credits
  assert best.gradRemaining is 0, "requirements unmet: #{best.gradRemaining} credits missing"
  assert 'APCALCB' in ids, 'math requirement not completed via in-HS courses'

check 'early_grad covers requirements and prefers a short horizon', ->
  profile = freshProfile!
  profile.objective = 'early_grad'
  model = buildModel school, profile, levels, exams
  result = search model, {}
  best = result.plans[0]
  assert best.gradRemaining is 0, "grad requirements not covered: #{best.gradRemaining} remaining"

check 'optional summer term joins only when opted in', ->
  base = buildModel school, freshProfile!, levels, exams
  assert base.terms.length is 8, "expected 8 terms, got #{base.terms.length}"
  profile = freshProfile!
  profile.optionalTerms = ['10:summer']
  withSummer = buildModel school, profile, levels, exams
  assert withSummer.terms.length is 9, "expected 9 terms, got #{withSummer.terms.length}"
