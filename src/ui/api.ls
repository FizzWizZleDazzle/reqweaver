# Client for the reqweaver API: goal encoding, and saving, reading,
# updating and deleting a plan. siteconfig's api_base names where the
# API lives; empty means this origin, which is how the site ships (one
# Worker serves the page and the API), so the request goes to a
# root-relative path.

base = (config) -> String((config or {}).api_base or '').replace /\/+$/, ''

url = (config, path) -> "#{base config}#{path}"

# The goal encoder, resolved for the worker: it runs off the page, so
# it is handed the finished URL rather than the config. Everything the
# API serves lives under /api, so one route covers it on any domain.
encodeUrl = (config) -> url config, '/api/encode'

# Where a saved plan is read: an absolute link, because it is meant to
# be copied and sent to someone.
shareUrl = (planId) ->
  origin = window.location?.origin or ''
  "#{origin}/s/#{planId}"

body = (response) -> response.json!.catch -> null

# Every call resolves to { ok, status, body }; nothing here throws.
# Saving is optional, and a failure is a line on screen, not a broken
# page.
send = (config, path, options) ->
  answer = fetch((url config, path), options or {}).then (response) ->
    body(response).then (parsed) -> { ok: response.ok, status: response.status, body: parsed }
  answer.catch (error) -> { ok: false, status: 0, body: null, error: String(error?.message or error) }

withJson = (method, payload, token) ->
  headers = { 'content-type': 'application/json' }
  headers.authorization = "Bearer #{token}" if token?
  { method: method, headers: headers, body: JSON.stringify payload }

savePlan = (config, payload) ->
  send config, '/api/plans', withJson 'POST', payload

readPlan = (config, planId) ->
  send config, "/api/plans/#{encodeURIComponent planId}", { method: 'GET' }

updatePlan = (config, planId, token, payload) ->
  send config, "/api/plans/#{encodeURIComponent planId}", withJson 'PUT', payload, token

deletePlan = (config, planId, token) ->
  headers = { authorization: "Bearer #{token}" }
  send config, "/api/plans/#{encodeURIComponent planId}", { method: 'DELETE', headers: headers }

module.exports = { base, url, encodeUrl, shareUrl, savePlan, readPlan, updatePlan, deletePlan }
