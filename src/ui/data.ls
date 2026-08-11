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

loadSchool = (entry) -> fetchYaml entry.path

loadLevels = -> fetchYaml 'data/registry/levels.yaml'

# Where a claim in the UI comes from, for the provenance links.
sourceUrl = (entry) -> entry.path

module.exports = { fetchText, fetchYaml, fetchJson, loadIndex, loadSchool, loadLevels, sourceUrl }
