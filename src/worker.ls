# Web Worker entry: the whole planner runs here so a solve never blocks the
# page. The worker fetches the specsheet, the registries, the weights, and
# (when the student states a goal) the school's course vectors, builds the
# model, searches, scores, and posts plain objects back. It also answers
# 'validate' messages: the rule check behind the manual grid, which runs
# on every placement and must return quickly.

yaml = require 'js-yaml'
{ buildModel } = require './engine/dag'
{ search, estBanked } = require './engine/search'
{ explain } = require './engine/explain'
{ hints } = require './engine/hints'
{ validate } = require './engine/validate'
{ rank } = require './scoring/scorer'
standing = require './standing'

LEVELS = 'data/registry/levels.yaml'
EXAMS = 'data/registry/exams.yaml'
SCORER = 'data/weights/scorer-weights.yaml'
TUNING = 'data/weights/engine.yaml'

NO_ENCODER = 'This build names no goal encoding endpoint, and this school precompiled no vector for that wording, so the plans below are not steered toward your goal.'

# Fetched files never change during a session, so cache the promises. The
# worker outlives a solve, so an encoder loaded for one run is still in
# memory for the next.
cache = {}

fetchBody = (url) ->
  fetch(url).then (response) ->
    unless response.ok
      throw new Error "could not load #{url} (#{response.status})"
    response

fetchYaml = (url) ->
  unless cache[url]?
    text = fetchBody(url).then (response) -> response.text!
    cache[url] = text.then (body) -> yaml.load body
  cache[url]

fetchJson = (url) ->
  unless cache[url]?
    cache[url] = fetchBody(url).then (response) -> response.json!
  cache[url]

post = (message) !-> self.postMessage message

# Goal vectors, by exact goal text, for the life of the worker: re-solving
# after a profile edit does not re-encode a goal that has not changed.
goalCache = {}

# A vector is only usable if it is the right width and can be scaled to
# unit length, since cosine against the course vectors assumes both. The
# course vectors ship normalized; a service response is normalized here
# again rather than trusted.
usableVector = (given, dim) ->
  return null unless Array.isArray(given) and given.length
  return null if dim? and given.length isnt dim
  norm = 0
  for v in given
    return null unless typeof v is 'number' and isFinite v
    norm += v * v
  norm = Math.sqrt norm
  return null unless norm > 0
  [v / norm for v in given]

# Turn a free-text goal into a vector in the space the school's course
# vectors live in: a goal the school precompiled first, otherwise the
# encoding service when the build configures one. Anything else resolves
# to no vector and the solve runs unsteered.
encodeGoal = (text, embeddings, api) ->
  return Promise.resolve goalCache[text] if goalCache[text]?
  dim = embeddings?.dim
  precomputed = usableVector embeddings?.goals?[text], dim
  if precomputed?
    goalCache[text] = { vector: precomputed, source: 'precomputed' }
    return Promise.resolve goalCache[text]
  unless api? and api.length
    return Promise.resolve { vector: null, reason: 'unconfigured' }
  post { type: 'status', phase: 'encoding' }
  answer = fetch api, {
    method: 'POST'
    headers: { 'content-type': 'application/json' }
    body: JSON.stringify { text: text }
  }
  body = answer.then (response) ->
    throw new Error "the goal service answered #{response.status}" unless response.ok
    response.json!
  encoded = body.then (result) ->
    vector = usableVector result?.vector, dim
    return { vector: null, reason: 'unusable' } unless vector?
    goalCache[text] = { vector: vector, source: 'encoded' }
    goalCache[text]
  encoded.catch -> { vector: null, reason: 'unreachable' }

noticeFor = (reason) ->
  switch reason
  | 'unconfigured' => NO_ENCODER
  | 'unusable' => 'The goal service answered with something this build cannot use, so the plans below are not steered toward your goal.'
  | otherwise => 'The goal service did not answer, so the plans below are not steered toward your goal.'

# Attach the semantic layer the engine reads: the school's precomputed
# course vectors plus a vector for the student's goal. Everything here is
# optional and inert when absent; the search runs either way.
applyGoal = (model, job) ->
  goal = (job.profile?.goal or '').trim!
  return Promise.resolve { goal: null } unless goal.length and job.embeddingsPath?
  post { type: 'status', phase: 'embeddings' }
  fetchJson(job.embeddingsPath).then (embeddings) ->
    model.embeddings = embeddings
    encodeGoal(goal, embeddings, job.encodeApi).then (encoded) ->
      if encoded.vector?
        model.goalVec = encoded.vector
        { goal: goal, source: encoded.source }
      else
        { goal: goal, source: null, notice: noticeFor encoded.reason }

# A plan state carries Sets and back-references; the UI needs the term
# assignments, the banked-credit estimate, the coverage totals, the
# scores, and why each course earned its slot. Everything posted is a
# plain structured-clone value.
serialize = (model, entry) ->
  {
    terms: entry.st.plan
    banked: entry.st.banked
    gradRemaining: entry.st.gradRemaining
    coverage: {} <<< entry.st.coverage
    signature: entry.st.sig
    objectiveScore: entry.st.g
    soft: entry.soft
    features: {} <<< entry.features
    why: explain model, entry.st
  }

# The grid on screen is standing, not a proposal, up to the marker: the
# courses in the terms behind it are held, and the search starts after
# them. The profile is copied rather than edited so nothing derived is
# ever written back to the student's file.
applyStanding = (school, job) ->
  profile = job.profile or {}
  derived = standing.derive school, profile, (job.standingPlan or []), profile.now
  return { profile: profile, past: [], cut: -1 } if derived.cut < 0
  next = {} <<< profile
  next.completed = derived.completed
  next.inProgress = derived.inProgress
  { profile: next, past: derived.past, cut: derived.cut }

bankedIn = (model, entries) ->
  total = 0
  for entry in entries
    for id in entry.courses
      course = model.courses[id]
      total += (estBanked course, model.levels, model.exams) if course?
  total

# Hints re-solve nearby profiles from scratch, so their probe must see
# the same horizon the plan covers: with a marker set, grades already
# finished are dropped from the school the probe builds on.
probeModel = (model, cut) ->
  return model if cut < 0
  school = {} <<< model.school
  school.grade_levels = standing.remainingGrades model.school, model.profile.now
  {} <<< model <<< { school: school }

advise = (model, result, options, cut, id) !->
  try
    post { type: 'hints', id: id, hints: hints (probeModel model, cut), result, options }
  catch e
    post { type: 'hints', id: id, hints: [] }

solve = (job) !->
  started = Date.now!
  post { type: 'status', phase: 'loading' }
  files = [
    fetchYaml job.schoolPath
    fetchYaml LEVELS
    fetchYaml EXAMS
    fetchYaml SCORER
    fetchYaml TUNING
  ]
  run = Promise.all(files).then (parts) ->
    [school, levels, exams, weights, tuning] = parts
    post { type: 'status', phase: 'building' }
    held = applyStanding school, job
    model = buildModel school, held.profile, levels, exams
    model.terms = standing.trimTerms school, model.terms, held.cut
    applyGoal(model, job).then (semantic) ->
      post { type: 'status', phase: 'searching', terms: model.terms.length }
      options = { tuning: tuning }
      options.beam = job.beam if job.beam?
      result = search model, options
      post { type: 'status', phase: 'scoring' }
      ranked = rank model, result.plans, weights
      top = job.top or 3
      post {
        type: 'done'
        id: job.id
        objective: result.objective
        warnings: result.warnings
        planCount: result.plans.length
        plans: [serialize model, entry for entry in ranked.slice 0, top]
        past: held.past
        bankedPast: bankedIn model, held.past
        goal: semantic.goal
        goalSource: semantic.source or null
        notice: semantic.notice or null
        elapsedMs: Date.now! - started
      }
      advise model, result, options, held.cut, job.id
  run.catch (error) !->
    post { type: 'error', id: job.id, message: String(error?.message or error) }

# The manual grid's rule check: build the model the solve path builds,
# run validate over the grid, and answer. No search and no goal
# encoding on this path; it is quick enough to run on every grid change.
check = (job) !->
  files = [
    fetchYaml job.schoolPath
    fetchYaml LEVELS
    fetchYaml EXAMS
  ]
  run = Promise.all(files).then (parts) ->
    [school, levels, exams] = parts
    model = buildModel school, (job.profile or {}), levels, exams
    report = validate model, (job.plan or [])
    post {
      type: 'validated'
      id: job.id
      issues: report.issues
      requirements: report.requirements
      remaining: report.remaining
      coverage: report.coverage
      banked: bankedIn model, (job.plan or [])
    }
  run.catch (error) !->
    post { type: 'error', id: job.id, message: String(error?.message or error) }

self.addEventListener 'message', (event) !->
  job = event.data
  return unless job?
  solve job if job.type is 'solve'
  check job if job.type is 'validate'
