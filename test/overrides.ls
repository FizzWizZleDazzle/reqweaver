# Student overrides: pins always win, waivers stand in for prereqs, and
# avoided (dragged-out) courses never come back.

assert = require 'assert'
{ school, levels, exams, check, freshProfile, planCourseIds, verifyFeasible } = require './helpers'
{ buildModel } = require '../engine/dag'
{ search } = require '../engine/search'

check 'valid pin is honored silently', ->
  profile = freshProfile!
  profile.pinned = [{ grade: 9, term: 'fall', courses: ['ENG1A'] },
                    { grade: 9, term: 'fall', courses: [] }]
  model = buildModel school, profile, levels, exams
  result = search model, {}
  assert result.warnings.length is 0, "unexpected warnings: #{result.warnings.join '; '}"
  for state in result.plans
    assert 'ENG1A' in state.plan[0].courses, 'pin not honored'

check 'rule-breaking pin is an override: honored with a warning', ->
  profile = freshProfile!
  profile.pinned = [{ grade: 9, term: 'fall', courses: ['APCALCA'] }]  # prereqs unmet, grade window 10+
  model = buildModel school, profile, levels, exams
  result = search model, {}
  assert result.warnings.length > 0, 'override produced no warning'
  for state in result.plans
    assert 'APCALCA' in state.plan[0].courses, 'override pin was not honored'
    verifyFeasible model, state

check 'a waiver stands in for prerequisites', ->
  profile = freshProfile!
  profile.waivers = ['GEOA']   # e.g. placement test; GEOA normally needs ALG1B
  # pinned into the first term: legal only because of the waiver, so
  # the pin must be honored silently, with no override warning
  profile.pinned = [{ grade: 9, term: 'fall', courses: ['GEOA'] }]
  model = buildModel school, profile, levels, exams
  result = search model, {}
  overrides = [w for w in result.warnings when w.indexOf('override') >= 0]
  assert overrides.length is 0, "waived pin still warned: #{overrides.join '; '}"
  assert 'GEOA' in result.plans[0].plan[0].courses, 'waived pin not scheduled'
  for state in result.plans
    verifyFeasible model, state

check 'avoided courses never appear in plans', ->
  profile = freshProfile!
  profile.avoid = ['ELEC1', 'ELEC2']
  model = buildModel school, profile, levels, exams
  result = search model, {}
  for state in result.plans
    ids = planCourseIds state
    assert 'ELEC1' not in ids, 'avoided course scheduled'
    assert 'ELEC2' not in ids, 'avoided course scheduled'
