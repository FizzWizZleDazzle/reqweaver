# Shared test scaffolding: fixture loading, the check harness, and the
# feasibility replay every plan-producing test leans on.

fs = require 'fs'
path = require 'path'
yaml = require 'js-yaml'
assert = require 'assert'
{ prereqsMet, pairSlots } = require '../engine/dag'

ROOT = path.join __dirname, '..', '..'
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

summary = ->
  if failures > 0
    console.log "\n#{failures} failure(s)"
    process.exit 1
  console.log '\nall tests passed'

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
  termsByKey = {}
  for t in model.terms
    termsByKey["#{t.grade}:#{t.term}"] = t
  done = new Set(model.done0)
  for entry in state.plan
    term = termsByKey["#{entry.grade}:#{entry.term}"]
    # sequential terms (summer sessions) count an A/B pair as one slot
    # and let a course follow its prerequisite within the term
    seq = term? and term.sequential
    cap = model.school.max_courses_per_term
    cap = term.maxCourses if term? and term.maxCourses?
    load = if seq then (pairSlots entry.courses, model.pairA) else entry.courses.length
    assert (not cap? or load <= cap), "course cap violated in #{entry.grade}:#{entry.term}"
    prereqDone = done
    if seq
      prereqDone = new Set(done)
      for id in entry.courses
        prereqDone.add id
    for id in entry.courses
      assert not done.has(id), "#{id} taken twice"
      continue if overridden.has id
      course = model.courses[id]
      assert course?, "unknown course #{id}"
      offered = (entry.term in (course.offered_terms or [])) or
                (term? and term.offerings? and id in term.offerings) or
                (term? and term.open)
      assert offered, "#{id} not offered in #{entry.term}"
      assert entry.grade in course.grade_levels, "#{id} outside grade window in grade #{entry.grade}"
      assert (model.waivers.has(id) or prereqsMet course, prereqDone, model.contentEquiv), "#{id} taken before its prereqs"
    for id in entry.courses
      done.add id

module.exports = {
  ROOT, loadYaml, school, levels, exams, weights,
  check, summary, freshProfile, cloneSchool, planCourseIds, verifyFeasible
}
