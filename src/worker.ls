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

NO_GOAL_VECTOR = 'Only goals precompiled for this school steer plans today; encoding a free-text goal needs the encoder service, which is coming. The plans below ignore this goal.'

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

# Turn a free-text goal into a vector in the space the school's course
# vectors live in. Today the only source is the school's own precompiled
# goals; anything else resolves null and the solve runs without steering.
# The encoder service, when there is one, arrives as `encoderUrl` from the
# staged index (tools/webdata.ls) and is the only thing this function needs
# to gain.
encodeGoal = (text, embeddings, encoderUrl) ->
  precomputed = embeddings?.goals?[text]
  return Promise.resolve { vector: precomputed, source: 'precomputed' } if precomputed?
  Promise.resolve { vector: null, source: null }

# Attach the semantic layer the engine reads: the school's precomputed
# course vectors plus a vector for the student's goal. Everything here is
# optional and inert when absent; the search runs either way.
applyGoal = (model, job) ->
  goal = (job.profile?.goal or '').trim!
  return Promise.resolve { goal: null } unless goal.length and job.embeddingsPath?
  post { type: 'status', phase: 'embeddings' }
  fetchJson(job.embeddingsPath).then (embeddings) ->
    model.embeddings = embeddings
    encodeGoal(goal, embeddings, job.encoderUrl).then (encoded) ->
      if encoded.vector?
        model.goalVec = encoded.vector
        { goal: goal, source: encoded.source }
      else
        { goal: goal, source: null, notice: NO_GOAL_VECTOR }

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
