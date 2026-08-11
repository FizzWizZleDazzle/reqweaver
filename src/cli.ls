# Standalone planner CLI.
# Usage: node lib/cli.js --school <specsheet.yaml> --profile <profile.yaml>
#        [--weights <weights.yaml>] [--objective max_credits|early_grad]
#        [--beam N] [--top N]

fs = require 'fs'
path = require 'path'
yaml = require 'js-yaml'
{ buildModel } = require './engine/dag'
{ search } = require './engine/search'
{ rank } = require './scoring/scorer'

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

printPlan = (model, entry, index) ->
  state = entry.st
  console.log "\n== plan #{index}  banked-credit estimate: #{state.banked}  grad credits remaining: #{state.gradRemaining}  soft: #{entry.soft.toFixed 3}"
  for term in state.plan
    names = []
    for id in term.courses
      course = model.courses[id]
      names.push (if course? then "#{id} #{course.name}" else id)
    console.log "  grade #{term.grade} #{term.term}: #{if names.length then names.join ' | ' else '(open)'}"

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
