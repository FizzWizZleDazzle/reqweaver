# Static data loading. The build publishes the school specsheets, the
# registries, and the weights files under public/data/ together with a
# generated index; the app fetches them and nothing else.

yaml = require 'js-yaml'

fetchText = (url) ->
  fetch(url).then (response) ->
    unless response.ok
      throw new Error "could not load #{url} (#{response.status})"
    response.text!

fetchYaml = (url) -> fetchText(url).then (text) -> yaml.load text

fetchJson = (url) -> fetchText(url).then (text) -> JSON.parse text

loadIndex = -> fetchJson 'data/index.json'

# Deployment settings staged from siteconfig.yaml. A build without one is
# not an error: every setting in it is optional.
loadSiteConfig = -> fetchJson('data/siteconfig.json').catch -> {}

loadSchool = (entry) -> fetchYaml entry.path

# Partner college sheets resolve from their id under the specs root the
# school was staged from: us/md/mcps/mc -> data/specs/us/md/mcps/mc.yaml,
# with course vectors beside it as embeddings.mc.json. Colleges are not
# in the discovery index by design, so the path is derived, not looked up.
specsRoot = (entry) ->
  suffix = "#{entry.id}.yaml"
  return null unless entry.path? and entry.path.slice(-suffix.length) is suffix
  entry.path.slice 0, entry.path.length - suffix.length

partnerPath = (entry, college) ->
  root = specsRoot entry
  if root? then "#{root}#{college}.yaml" else null

partnerEmbeddingsPath = (entry, college) ->
  root = specsRoot entry
  return null unless root?
  at = college.lastIndexOf '/'
  dir = if at >= 0 then college.slice(0, at + 1) else ''
  stem = if at >= 0 then college.slice(at + 1) else college
  "#{root}#{dir}embeddings.#{stem}.json"

# Loaded partner sheets, by path, for the life of the page: flipping the
# dual-enrollment toggle or revisiting a school does not re-parse them.
partnerCache = {}

loadPartner = (path) ->
  partnerCache[path] = fetchYaml path unless partnerCache[path]?
  partnerCache[path]

loadLevels = -> fetchYaml 'data/registry/levels.yaml'

# Where a claim in the UI comes from, for the provenance links.
sourceUrl = (entry) -> entry.path

module.exports = {
  fetchText, fetchYaml, fetchJson, loadIndex, loadSiteConfig, loadSchool,
  partnerPath, partnerEmbeddingsPath, loadPartner, loadLevels, sourceUrl
}
