# Hand-built plan validation: the manual planner's live rule feedback.
# A feasible search plan must validate clean, and every rule violation
# must come back as a typed issue, never a refusal.

assert = require 'assert'
{ school, levels, exams, check, freshProfile } = require './helpers'
{ buildModel } = require '../engine/dag'
{ search } = require '../engine/search'
{ validate } = require '../engine/validate'

check 'a search plan validates with no issues', ->
  model = buildModel school, freshProfile!, levels, exams
  result = search model, {}
  report = validate model, result.plans[0].plan
  assert.strictEqual report.issues.length, 0, "issues on a feasible plan: #{JSON.stringify report.issues}"
  assert.strictEqual report.remaining, 0, 'search plan left requirements uncovered'

check 'each violated rule becomes a typed issue', ->
  model = buildModel school, freshProfile!, levels, exams
  plan = [{ grade: 9, term: 'fall', courses: ['GEOB', 'APCALCA', 'ELEC1', 'ELEC2'] }]
  report = validate model, plan
  kinds = {}
  for i in report.issues
    kinds[i.kind] = true
  assert kinds.prereq, 'unmet prerequisites not flagged'
  assert kinds.offering, 'spring-only course placed in fall not flagged'
  assert kinds.grade, 'grade-10+ course in grade 9 not flagged'
  assert kinds.capacity, 'four courses over the three-period cap not flagged'

check 'same-content variants in one term are a conflict', ->
  model = buildModel school, freshProfile!, levels, exams
  report = validate model, [{ grade: 9, term: 'fall', courses: ['GEOA', 'GEOHA'] }]
  conflicts = [i for i in report.issues when i.kind is 'conflict']
  assert conflicts.length > 0, 'same content group in one term not flagged'

check 'unknown ids and repeats across terms are flagged', ->
  model = buildModel school, freshProfile!, levels, exams
  fall9 = { grade: 9, term: 'fall', courses: ['ENG1A', 'NOPE'] }
  fall10 = { grade: 10, term: 'fall', courses: ['ENG1A'] }
  report = validate model, [fall9, fall10]
  kinds = {}
  for i in report.issues
    kinds[i.kind] = true
  assert kinds.unknown, 'unknown course id not flagged'
  assert kinds.duplicate, 'course repeated in a later term not flagged'

check 'the requirement tracker credits a partial hand-built plan', ->
  model = buildModel school, freshProfile!, levels, exams
  fall = { grade: 9, term: 'fall', courses: ['ENG1A', 'ALG1A', 'ART1A'] }
  spring = { grade: 9, term: 'spring', courses: ['ENG1B', 'ALG1B', 'ART1B'] }
  report = validate model, [fall, spring]
  assert.strictEqual report.issues.length, 0, "clean first year raised: #{JSON.stringify report.issues}"
  for req in report.requirements
    assert.strictEqual req.have, 1.0, "#{req.id} should hold 1.0 credit"
  assert.strictEqual report.remaining, 2.0, 'total remaining credit wrong'

check 'a waiver clears the prereq issue like it does in search', ->
  profile = freshProfile!
  profile.waivers = ['GEOA']
  model = buildModel school, profile, levels, exams
  report = validate model, [{ grade: 9, term: 'fall', courses: ['GEOA'] }]
  prereq = [i for i in report.issues when i.kind is 'prereq']
  assert.strictEqual prereq.length, 0, 'waived course still flagged for prereqs'
