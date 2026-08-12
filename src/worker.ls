# Web Worker entry: the whole planner runs here so a solve never blocks the
# page. The worker fetches the specsheet, the registries, the weights, and
# (when the student states a goal) the school's course vectors, builds the
# model, searches, scores, and posts plain objects back.

yaml = require 'js-yaml'
{ buildModel } = require './engine/dag'
{ search } = require './engine/search'
{ rank } = require './scoring/scorer'

LEVELS = 'data/registry/levels.yaml'
EXAMS = 'data/registry/exams.yaml'
SCORER = 'data/weights/scorer-weights.yaml'
TUNING = 'data/weights/engine.yaml'

NO_ENCODER = 'This build has no goal encoding service configured, and this school precompiled no vector for that wording, so the plans below are not steered toward your goal.'

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
# assignments, the banked-credit estimate, the coverage totals, and the
# scores. Everything posted is a plain structured-clone value.
serialize = (entry) ->
  {
    terms: entry.st.plan
    banked: entry.st.banked
    gradRemaining: entry.st.gradRemaining
    coverage: {} <<< entry.st.coverage
    signature: entry.st.sig
    objectiveScore: entry.st.g
    soft: entry.soft
    features: {} <<< entry.features
  }

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
    model = buildModel school, job.profile, levels, exams
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
        plans: [serialize entry for entry in ranked.slice 0, top]
        goal: semantic.goal
        goalSource: semantic.source or null
        notice: semantic.notice or null
        elapsedMs: Date.now! - started
      }
  run.catch (error) !->
    post { type: 'error', id: job.id, message: String(error?.message or error) }

self.addEventListener 'message', (event) !->
  job = event.data
  return unless job? and job.type is 'solve'
  solve job
