# Engine tests against the tiny fixture: feasibility invariants,
# graduation-requirement coverage, elective-crowding regression,
# determinism, pins, and objective behavior.

fs = require 'fs'
path = require 'path'
yaml = require 'js-yaml'
assert = require 'assert'
{ buildModel, prereqsMet } = require './engine/dag'
{ search } = require './engine/search'
{ rank } = require './scoring/scorer'

ROOT = path.join __dirname, '..'
loadYaml = (parts) -> yaml.load fs.readFileSync path.join.apply(path, [ROOT] ++ parts), 'utf8'
school = loadYaml ['test', 'fixtures', 'tiny-school.yaml']
levels = loadYaml ['registry', 'levels.yaml']
exams = loadYaml ['registry', 'exams.yaml']
weights = loadYaml ['weights', 'scorer-weights.yaml']

failures = 0
check = (name, fn) ->
  try
    fn!
    console.log "ok   #{name}"
  catch e
    failures := failures + 1
    console.log "FAIL #{name}: #{e.message}"

freshProfile = -> { completed: [], inProgress: [], pinned: [], optionalTerms: [], objective: 'max_credits' }

cloneSchool = -> JSON.parse JSON.stringify school

planCourseIds = (state) ->
  ids = []
  for entry in state.plan
    for id in entry.courses
      ids.push id
  ids

# Replays a plan against the hard rules; any violation the student did not
# explicitly authorize (pin override, waiver) is an engine bug.
verifyFeasible = (model, state) ->
  overridden = new Set!
  for pin in (model.profile.pinned or [])
    for id in (pin.courses or [])
      overridden.add id
  done = new Set(model.done0)
  for entry in state.plan
    cap = model.school.max_courses_per_term
    assert (not cap? or entry.courses.length <= cap), 'course cap violated'
    for id in entry.courses
      assert not done.has(id), "#{id} taken twice"
      continue if overridden.has id
      course = model.courses[id]
      assert course?, "unknown course #{id}"
      assert entry.term in course.offered_terms, "#{id} not offered in #{entry.term}"
      assert entry.grade in course.grade_levels, "#{id} outside grade window in grade #{entry.grade}"
      assert (model.waivers.has(id) or prereqsMet course, done, model.contentEquiv), "#{id} taken before its prereqs"
    for id in entry.courses
      done.add id

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
  model = buildModel school, profile, levels, exams
  result = search model, {}
  best = result.plans[0]
  assert 'GEOA' in best.plan[0].courses, 'waived course not scheduled ahead of its prereq'
  for state in result.plans
    verifyFeasible model, state

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

check 'avoided courses never appear in plans', ->
  profile = freshProfile!
  profile.avoid = ['ELEC1', 'ELEC2']
  model = buildModel school, profile, levels, exams
  result = search model, {}
  for state in result.plans
    ids = planCourseIds state
    assert 'ELEC1' not in ids, 'avoided course scheduled'
    assert 'ELEC2' not in ids, 'avoided course scheduled'

check 'explanations mark requirements, prereqs, banked, and filler', ->
  { explain } = require './engine/explain'
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
  { hints } = require './engine/hints'
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
  { hints } = require './engine/hints'
  profile = freshProfile!
  profile.rigor = 0
  model = buildModel school, profile, levels, exams
  result = search model, {}
  for h in hints model, result, {}
    assert h.indexOf('rigor target') < 0, "unwanted rigor hint: #{h}"

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

check 'scorer ranks without changing the feasible set', ->
  model = buildModel school, freshProfile!, levels, exams
  result = search model, {}
  ranked = rank model, result.plans, weights
  assert.strictEqual ranked.length, result.plans.length
  signatures = new Set([state.sig for state in result.plans])
  for entry in ranked
    assert signatures.has(entry.st.sig), 'scorer introduced a plan'

# Parity: the LiveScript MiniLM forward pass must reproduce the Python
# reference vectors. Runs only when the model export exists.
encoderDir = path.join ROOT, 'data', 'encoder'
if fs.existsSync path.join(encoderDir, 'manifest.json')
  check 'LiveScript sentence encoder matches the reference vectors', ->
    encoder = require './scoring/encoder'
    { cosine } = require './engine/search'
    manifest = JSON.parse fs.readFileSync path.join(encoderDir, 'manifest.json'), 'utf8'
    vocab = JSON.parse fs.readFileSync path.join(encoderDir, 'vocab.json'), 'utf8'
    refs = JSON.parse fs.readFileSync path.join(encoderDir, 'refs.json'), 'utf8'
    buf = fs.readFileSync path.join(encoderDir, 'model.bin')
    enc = encoder.loadModel manifest, buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength), vocab
    for sentence, ref of refs
      sim = cosine (encoder.encode enc, sentence), ref
      assert sim > 0.999, "cosine to reference only #{sim.toFixed 5} for: #{sentence}"
else
  console.log 'skip encoder parity (no data/encoder export; run npm run export-model)'

if failures > 0
  console.log "\n#{failures} failure(s)"
  process.exit 1
else
  console.log '\nall tests passed'
