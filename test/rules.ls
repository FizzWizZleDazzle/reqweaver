# Catalog rule semantics: requirement predicates, nested prerequisite
# trees, variant exclusion, rigor-driven variant choice, and sequence
# continuity.

assert = require 'assert'
{ school, levels, exams, loadYaml, check, freshProfile, cloneSchool, planCourseIds } = require './helpers'
{ buildModel, prereqsMet } = require '../engine/dag'
{ search } = require '../engine/search'

check 'course-list requirement predicates pull the sequence, not tag filler', ->
  seq = cloneSchool!
  for req in seq.grad_requirements when req.id is 'english'
    req.satisfied_by = { courses: ['ENG2A', 'ENG2B'] }
    req.credits = 1.0
  model = buildModel seq, freshProfile!, levels, exams
  result = search model, {}
  best = result.plans[0]
  ids = planCourseIds best
  assert best.gradRemaining is 0, "requirements unmet: #{best.gradRemaining}"
  assert ('ENG2A' in ids and 'ENG2B' in ids), 'course-list requirement not satisfied by the named courses'

check 'content-group requirement predicates accept any variant tier', ->
  seq = cloneSchool!
  geoReq = { id: 'geo', label: 'Geometry', credits: 1.0, satisfied_by: { content: ['geo_a', 'geo_b'] } }
  seq.grad_requirements = [geoReq]
  model = buildModel seq, freshProfile!, levels, exams
  result = search model, {}
  best = result.plans[0]
  ids = planCourseIds best
  assert best.gradRemaining is 0, "requirements unmet: #{best.gradRemaining}"
  tookRegular = 'GEOA' in ids and 'GEOB' in ids
  tookHonors = 'GEOHA' in ids and 'GEOHB' in ids
  assert (tookRegular or tookHonors), 'no geometry variant satisfied the content requirement'

check 'nested requires trees evaluate a or (c and (b or d))', ->
  course = { id: 'X', requires: { any: ['A', { all: ['C', { any: ['B', 'D'] }] }] } }
  met = (ids) -> prereqsMet course, new Set(ids)
  assert met(['A']), 'a alone satisfies'
  assert met(['C', 'B']), 'c and b satisfies'
  assert met(['C', 'D']), 'c and d satisfies'
  assert not met(['C']), 'c alone must not satisfy'
  assert not met(['B', 'D']), 'b and d without c must not satisfy'
  assert not met([]), 'empty must not satisfy'

check 'excludes prevents pairing irregular variants', ->
  variant = cloneSchool!
  for course in variant.courses when course.id is 'ELEC1'
    course.excludes = ['ELEC2']
  model = buildModel variant, freshProfile!, levels, exams
  result = search model, {}
  sawOne = false
  for state in result.plans
    ids = planCourseIds state
    both = 'ELEC1' in ids and 'ELEC2' in ids
    assert not both, 'excluded pair taken together'
    sawOne := true if 'ELEC1' in ids or 'ELEC2' in ids
  assert sawOne, 'vacuous: no plan touched the excluded pair'

check 'high rigor picks the honors variant, low rigor the regular one', ->
  run = (rigor) ->
    profile = freshProfile!
    profile.rigor = rigor
    profile.maxCoursesPerTerm = 2   # tight, so only one geometry track fits
    result = search buildModel(school, profile, levels, exams), {}
    planCourseIds result.plans[0]
  highIds = run 1
  assert 'GEOHA' in highIds, 'high rigor skipped honors geometry'
  assert 'GEOA' not in highIds, 'high rigor wasted a slot on regular geometry'
  lowIds = run 0
  assert 'GEOA' in lowIds, 'low rigor skipped regular geometry'
  assert 'GEOHA' not in lowIds, 'low rigor took the honors variant'

check 'continuity beats breadth: one language sequence, not two roots', ->
  twoLangs = loadYaml ['test', 'fixtures', 'two-langs.yaml']
  model = buildModel twoLangs, freshProfile!, levels, exams
  result = search model, {}
  best = result.plans[0]
  ids = planCourseIds best
  startedBoth = 'SPA1A' in ids and 'CHI1A' in ids
  assert not startedBoth, 'started two language sequences instead of continuing one'
  finished = ('SPA2B' in ids) or ('CHI2B' in ids)
  assert finished, 'did not carry the started sequence through level 2'
