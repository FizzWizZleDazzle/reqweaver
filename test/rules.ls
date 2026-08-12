# Catalog rule semantics: requirement predicates, nested prerequisite
# trees, variant exclusion, rigor-driven variant choice, and sequence
# continuity.

assert = require 'assert'
{ school, levels, exams, loadYaml, check, freshProfile, cloneSchool, planCourseIds, verifyFeasible } = require './helpers'
{ buildModel, prereqsMet } = require '../engine/dag'
{ search, eagerness, mergeTuning } = require '../engine/search'
{ reqMatches } = require '../engine/gradreqs'

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

check 'grad_tags override subject tags for requirement matching', ->
  req = { id: 'health', credits: 1.0, satisfied_by: { tag: 'health' } }
  college = { id: 'X', tags: ['elective', 'health'], grad_tags: ['elective'] }
  assert not (reqMatches req, college), 'subject tag satisfied a requirement despite grad_tags'
  assert (reqMatches req, { id: 'Y', tags: ['health'] }), 'plain tags stopped matching'

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

check 'dedication carries a started chain past richer electives', ->
  twoLangs = loadYaml ['test', 'fixtures', 'two-langs.yaml']
  profile = freshProfile!
  profile.preHsCompleted = ['SPA1A', 'SPA1B']
  profile.maxCoursesPerTerm = 1   # one slot: the chain must beat the AP electives outright
  model = buildModel twoLangs, profile, levels, exams
  result = search model, {}
  ids = planCourseIds result.plans[0]
  assert ('SPA2A' in ids and 'SPA3B' in ids), "started chain not carried: #{ids.join ','}"

check 'a disliked subject covers with the lightest variant, never as filler', ->
  profile = freshProfile!
  profile.rigor = 1
  profile.dislikes = ['math']
  model = buildModel school, profile, levels, exams
  result = search model, {}
  ids = planCourseIds result.plans[0]
  assert 'GEOA' in ids, 'regular geometry expected in a disliked subject'
  assert 'GEOHA' not in ids, 'honors variant taken despite the dislike'
  assert 'APCALCA' not in ids, 'AP filler taken in a disliked subject'

check 'two roots in one term score below one root plus filler', ->
  twoLangs = loadYaml ['test', 'fixtures', 'two-langs.yaml']
  model = buildModel twoLangs, freshProfile!, levels, exams
  model.tuning = mergeTuning {}
  at = (courses) -> [{ grade: 9, term: 'fall', courses: courses }]
  bothRoots = eagerness model, { plan: at ['CHI1A', 'SPA1A'] }
  oneRoot = eagerness model, { plan: at ['ELEC1', 'SPA1A'] }
  assert oneRoot > bothRoots, "same-term roots not damped: #{oneRoot} <= #{bothRoots}"

# Summer school compressed to one sequential term: an A/B pair fills
# one slot and exactly the 1.0-credit summer allowance, and B legally
# follows A inside the term.
summerSchool = ->
  seq = cloneSchool!
  seq.terms_per_year[2] = { id: 'summer', sequence: 3, optional: true, sequential: true, max_courses: 2, max_credits: 1.0, offerings: ['ALG1A', 'ALG1B', 'ELEC1', 'ELEC2', 'ELEC3'] }
  # algebra runs only in summer here, so covering math forces the pair
  # through the sequential term
  for course in seq.courses when course.id in ['ALG1A', 'ALG1B']
    course.offered_terms = []
  seq

check 'a sequential summer compresses an A/B pair into one session', ->
  profile = freshProfile!
  profile.optionalTerms = ['9:summer']
  model = buildModel summerSchool!, profile, levels, exams
  result = search model, {}
  best = result.plans[0]
  assert best.gradRemaining is 0, "requirements unmet: #{best.gradRemaining}"
  summer = null
  for entry in best.plan when entry.term is 'summer'
    summer := entry
  assert summer?, 'no summer entry in the plan'
  for id in ['ALG1A', 'ALG1B']
    assert id in summer.courses, "#{id} missing from the summer session"
  verifyFeasible model, best

check 'a split A/B pair scores below other filler at the same slot', ->
  model = buildModel school, freshProfile!, levels, exams
  model.tuning = mergeTuning {}
  planWith = (last) ->
    [{ grade: 9, term: 'fall', courses: ['ART1A'] },
     { grade: 9, term: 'spring', courses: [] },
     { grade: 10, term: 'fall', courses: [] },
     { grade: 10, term: 'spring', courses: [last] }]
  split = eagerness model, { plan: planWith 'ART1B' }
  filler = eagerness model, { plan: planWith 'ELEC1' }
  assert filler > split, "pair gap not penalized: #{filler} <= #{split}"
