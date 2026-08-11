# Web Worker entry: the whole planner runs here so a solve never blocks the
# page. The worker fetches the specsheet, the registries, and the weights
# itself, builds the model, searches, scores, and posts plain objects back.

yaml = require 'js-yaml'
{ buildModel } = require './engine/dag'
{ search } = require './engine/search'
{ rank } = require './scoring/scorer'

LEVELS = 'data/registry/levels.yaml'
EXAMS = 'data/registry/exams.yaml'
SCORER = 'data/weights/scorer-weights.yaml'
TUNING = 'data/weights/engine.yaml'

# Fetched files never change during a session, so cache the promises.
cache = {}

fetchYaml = (url) ->
  unless cache[url]?
    text = fetch(url).then (response) ->
      unless response.ok
        throw new Error "could not load #{url} (#{response.status})"
      response.text!
    cache[url] = text.then (body) -> yaml.load body
  cache[url]

post = (message) !-> self.postMessage message

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
      elapsedMs: Date.now! - started
    }
  run.catch (error) !->
    post { type: 'error', id: job.id, message: String(error?.message or error) }

self.addEventListener 'message', (event) !->
  job = event.data
  return unless job? and job.type is 'solve'
  solve job
