# Stages the static site: the page, the stylesheet, every school specsheet,
# its course embeddings, the registries, and the weights files land under
# public/, with a generated index listing the sheets the app can offer.
# Adding a school is adding a file under specsheets/schools; this picks it
# up.
# Run: node lib/tools/webdata.js   (npm run build:web does it for you)

fs = require 'fs'
path = require 'path'
yaml = require 'js-yaml'

ROOT = path.join __dirname, '..', '..'
OUT = path.join ROOT, 'public'

mkdirp = (dir) !-> fs.mkdirSync dir, { recursive: true }

copy = (from, to) !->
  mkdirp path.dirname to
  fs.copyFileSync from, to

walk = (dir) ->
  found = []
  return found unless fs.existsSync dir
  for name in fs.readdirSync dir
    full = path.join dir, name
    if fs.statSync(full).isDirectory!
      found = found ++ walk full
    else if name.slice(-5) is '.yaml'
      found.push full
  found

# The course vectors for a sheet, by convention embeddings.<sheet>.json
# beside it (tools/embed.py writes them there).
embeddingsBeside = (file) ->
  base = path.basename(file).replace /\.ya?ml$/, ''
  candidate = path.join (path.dirname file), "embeddings.#{base}.json"
  if fs.existsSync candidate then candidate else null

main = !->
  mkdirp OUT

  for name in ['index.html', 'styles.css']
    copy (path.join ROOT, 'src', 'ui', name), (path.join OUT, name)

  for name in ['levels.yaml', 'exams.yaml']
    copy (path.join ROOT, 'registry', name), (path.join OUT, 'data', 'registry', name)

  for name in ['scorer-weights.yaml', 'engine.yaml']
    copy (path.join ROOT, 'weights', name), (path.join OUT, 'data', 'weights', name)

  schoolsDir = path.join ROOT, 'specsheets', 'schools'
  entries = []
  embedded = 0
  for file in walk schoolsDir
    sheet = yaml.load fs.readFileSync file, 'utf8'
    continue unless sheet? and sheet.id?
    relative = path.relative schoolsDir, file
    target = path.join OUT, 'data', 'schools', relative
    copy file, target
    entry = {
      id: sheet.id
      name: sheet.name or sheet.id
      kind: sheet.kind or 'high_school'
      catalogYear: sheet.catalog_year
      schemaVersion: sheet.schema_version
      courses: (sheet.courses or []).length
      path: "data/schools/#{relative.split(path.sep).join '/'}"
    }
    vectors = embeddingsBeside file
    if vectors?
      relativeVectors = path.relative schoolsDir, vectors
      copy vectors, (path.join OUT, 'data', 'schools', relativeVectors)
      entry.embeddings = "data/schools/#{relativeVectors.split(path.sep).join '/'}"
      embedded += 1
    entries.push entry
  entries.sort (a, b) -> if a.name < b.name then -1 else 1

  # `encoder` is the one place the goal-encoding service URL arrives from,
  # once there is one. Null means the app can only use goals a school
  # precomputed, which is the state today.
  index = { generated: 1, encoder: null, schools: entries }
  fs.writeFileSync (path.join OUT, 'data', 'index.json'), JSON.stringify(index, null, 2) + '\n'
  console.log "staged #{entries.length} school sheets (#{embedded} with course vectors) into public/data"

main!
