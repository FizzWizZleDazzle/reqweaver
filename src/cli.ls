# Standalone planner CLI.
# Usage: node lib/cli.js --school <specsheet.yaml> --profile <profile.yaml>
#        [--weights <weights.yaml>] [--objective max_credits|early_grad]
#        [--beam N] [--top N]

fs = require 'fs'
path = require 'path'
yaml = require 'js-yaml'
{ buildModel } = require './engine/dag'
{ search } = require './engine/search'
{ explain } = require './engine/explain'
{ rank } = require './scoring/scorer'
encoder = require './scoring/encoder'

ROOT = path.join __dirname, '..'

parseArgs = (argv) ->
  args = {}
  i = 0
  while i < argv.length
    if argv[i].slice(0, 2) is '--'
      args[argv[i].slice 2] = argv[i + 1]
      i += 2
    else
      i += 1
  args

# YAML is the project's file format; js-yaml also accepts JSON as a subset.
load = (file) ->
  yaml.load fs.readFileSync(file, 'utf8')

# The exported sentence encoder (tools/export-encoder.py), when present.
loadEncoder = ->
  dir = path.join ROOT, 'data', 'encoder'
  return null unless fs.existsSync path.join(dir, 'manifest.json')
  manifest = JSON.parse fs.readFileSync path.join(dir, 'manifest.json'), 'utf8'
  vocab = JSON.parse fs.readFileSync path.join(dir, 'vocab.json'), 'utf8'
  buf = fs.readFileSync path.join(dir, 'model.bin')
  ab = buf.buffer.slice buf.byteOffset, buf.byteOffset + buf.byteLength
  encoder.loadModel manifest, ab, vocab

printPlan = (model, entry, index) ->
  state = entry.st
  why = explain model, state
  console.log "\n== plan #{index}  banked-credit estimate: #{state.banked}  grad credits remaining: #{state.gradRemaining}  soft: #{entry.soft.toFixed 3}"
  for term in state.plan
    names = []
    for id in term.courses
      course = model.courses[id]
      names.push (if course? then "#{id} #{course.name}" else id)
    console.log "  grade #{term.grade} #{term.term}: #{if names.length then names.join ' | ' else '(open)'}"
  swappable = []
  for id, info of why when info.necessity < 0.2
    course = model.courses[id]
    swappable.push (if course? then "#{id} #{course.name}" else id)
  if swappable.length
    console.log "  swappable filler (drag out for a TA period or anything you prefer): #{swappable.join ' | '}"

main = ->
  args = parseArgs process.argv.slice 2
  unless args.school and args.profile
    console.error 'usage: cli --school <specsheet.yaml> --profile <profile.yaml> [--weights w.yaml] [--objective X] [--beam N] [--top N]'
    process.exit 2
  school = load args.school
  profile = load args.profile
  profile.objective = args.objective if args.objective
  profile.rigor = parseFloat args.rigor if args.rigor
  levels = load path.join(ROOT, 'registry', 'levels.yaml')
  exams = load path.join(ROOT, 'registry', 'exams.yaml')
  weights = load(args.weights or path.join(ROOT, 'weights', 'scorer-weights.yaml'))
  model = buildModel school, profile, levels, exams
  # semantic layer: precompiled course embeddings for this school, and the
  # goal encoded at runtime by the LiveScript MiniLM forward pass (falls
  # back to a precomputed goal vector when the model export is absent)
  embPath = args.embeddings or
    path.join (path.dirname args.school), 'embeddings.' + path.basename(args.school).replace(/\.ya?ml$/, '') + '.json'
  if fs.existsSync embPath
    model.embeddings = JSON.parse fs.readFileSync(embPath, 'utf8')
    if profile.goal?
      enc = loadEncoder!
      model.goalVec =
        if enc? then encoder.encode enc, profile.goal
        else model.embeddings.goals?[profile.goal]
      console.log "goal '#{profile.goal}': no encoder export and no precomputed vector; run npm run export-model" unless model.goalVec?
  options = { tuning: load(args.tuning or path.join(ROOT, 'weights', 'engine.yaml')) }
  options.beam = parseInt(args.beam, 10) if args.beam
  result = search model, options
  ranked = rank model, result.plans, weights
  top = parseInt(args.top or '3', 10)
  console.log "objective: #{result.objective}   plans found: #{result.plans.length}   showing top #{Math.min top, ranked.length}"
  for warning in result.warnings
    console.log "warning: #{warning}"
  for entry, i in ranked
    break if i >= top
    printPlan model, entry, i + 1

main!
