# The soft layer: scorer isolation, plan explanations, and advisory
# hints.

assert = require 'assert'
{ school, levels, exams, weights, check, freshProfile, cloneSchool, planCourseIds } = require './helpers'
{ buildModel } = require '../engine/dag'
{ search } = require '../engine/search'
{ explain } = require '../engine/explain'
{ hints } = require '../engine/hints'
{ rank } = require '../scoring/scorer'

check 'scorer ranks without changing the feasible set', ->
  model = buildModel school, freshProfile!, levels, exams
  result = search model, {}
  ranked = rank model, result.plans, weights
  assert.strictEqual ranked.length, result.plans.length
  signatures = new Set([state.sig for state in result.plans])
  for entry in ranked
    assert signatures.has(entry.st.sig), 'scorer introduced a plan'

check 'explanations mark requirements, prereqs, banked, and filler', ->
  model = buildModel school, freshProfile!, levels, exams
  result = search model, {}
  best = result.plans[0]
  why = explain model, best
  ids = planCourseIds best
  kinds = (id) -> [r.kind for r in why[id].reasons]
  assert 'requirement' in kinds('ART1A'), 'art requirement course not marked required'
  geoA = if 'GEOHA' in ids then 'GEOHA' else 'GEOA'
  assert 'prerequisite' in kinds(geoA), 'geometry not marked as a prerequisite'
  assert 'banked' in kinds('APCALCA'), 'AP course not marked as banking credit'
  for id in ids when id.slice(0, 4) is 'ELEC'
    assert why[id].necessity < 0.2, "elective #{id} not marked swappable"

check 'a high-rigor plan stuck on the gentle track earns a rigor hint', ->
  gentle = cloneSchool!
  # strip the intense variants so the plan cannot reach the target
  gentle.courses = [c for c in gentle.courses when c.level is 'regular']
  profile = freshProfile!
  profile.rigor = 1
  model = buildModel gentle, profile, levels, exams
  result = search model, {}
  advice = hints model, result, {}
  found = false
  for h in advice when h.indexOf('rigor target') >= 0
    found := true
  assert found, "no rigor hint in: #{advice.join ' / '}"

check 'a satisfied plan earns no rigor hint', ->
  profile = freshProfile!
  profile.rigor = 0
  model = buildModel school, profile, levels, exams
  result = search model, {}
  for h in hints model, result, {}
    assert h.indexOf('rigor target') < 0, "unwanted rigor hint: #{h}"
