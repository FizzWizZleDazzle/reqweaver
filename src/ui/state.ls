# Profile and UI state, persisted to localStorage on every change. The
# profile is exactly the shape the engine reads (see examples/*.yaml), so
# export writes a file the CLI can plan with and import accepts one.

yaml = require 'js-yaml'

KEY = 'reqweaver.v1'

LIST_FIELDS = <[ completed preHsCompleted inProgress waivers optionalTerms interests ]>

emptyProfile = ->
  {
    completed: []
    preHsCompleted: []
    inProgress: []
    pinned: []
    waivers: []
    optionalTerms: []
    rigor: 0.5
    interests: []
    goal: ''
    objective: 'max_credits'
    maxCoursesPerTerm: null
  }

defaults = ->
  { version: 1, schoolId: null, profile: emptyProfile!, ui: { beam: 100 } }

state = defaults!
listeners = []

# --- persistence -----------------------------------------------------------

load = !->
  try
    raw = window.localStorage?.getItem KEY
    return unless raw
    saved = JSON.parse raw
    return unless saved?
    state.schoolId = saved.schoolId if saved.schoolId?
    state.profile = normalize saved.profile
    state.ui = {} <<< state.ui <<< (saved.ui or {})
  catch e
    console.warn 'could not restore saved profile:', e

save = !->
  try
    window.localStorage?.setItem KEY, JSON.stringify state
  catch e
    console.warn 'could not save profile:', e

KNOWN = LIST_FIELDS ++ <[ pinned rigor goal objective maxCoursesPerTerm ]>

# Accept anything shaped like a profile and fill in what is missing, so a
# hand-written or older file still loads. Fields the editor does not know
# about ride along untouched: the engine may read them, and dropping them
# on import would lose part of the student's file.
normalize = (given) ->
  p = emptyProfile!
  return p unless given? and typeof given is 'object'
  for key, value of given when key not in KNOWN
    p[key] = value
  for field in LIST_FIELDS
    p[field] = [String v for v in given[field]] if Array.isArray given[field]
  if Array.isArray given.pinned
    for entry in given.pinned when entry? and entry.grade? and entry.term?
      p.pinned.push {
        grade: Number entry.grade
        term: String entry.term
        courses: [String c for c in (entry.courses or [])]
      }
  p.rigor = Number given.rigor if typeof given.rigor is 'number'
  p.goal = String given.goal if given.goal?
  p.objective = String given.objective if given.objective?
  p.maxCoursesPerTerm = Number given.maxCoursesPerTerm if given.maxCoursesPerTerm?
  p

# --- change notification ---------------------------------------------------

subscribe = (fn) !-> listeners.push fn

changed = !->
  save!
  for fn in listeners
    fn!

# --- accessors -------------------------------------------------------------

profile = -> state.profile
schoolId = -> state.schoolId
ui = -> state.ui

setSchool = (id) !->
  state.schoolId = id
  changed!

setUi = (key, value) !->
  state.ui[key] = value
  changed!

setField = (key, value) !->
  state.profile[key] = value
  changed!

has = (field, id) -> id in (state.profile[field] or [])

add = (field, id) !->
  list = state.profile[field]
  return if id in list
  list.push id
  changed!

remove = (field, id) !->
  state.profile[field] = [x for x in state.profile[field] when x isnt id]
  changed!

toggle = (field, id) !->
  if has field, id then remove field, id else add field, id

# A course belongs to at most one standing list: moving it to completed
# takes it out of in-progress and out of pre-HS.
STANDING = <[ completed preHsCompleted inProgress ]>

setStanding = (id, field) !->
  for other in STANDING when other isnt field
    state.profile[other] = [x for x in state.profile[other] when x isnt id]
  if field?
    state.profile[field].push id unless id in state.profile[field]
  changed!

standingOf = (id) ->
  found = null
  for field in STANDING when id in state.profile[field]
    found = field
  found

# --- pins ------------------------------------------------------------------

pinKey = (grade, term) -> "#{grade}:#{term}"

pinsFor = (grade, term) ->
  for entry in state.profile.pinned when entry.grade is grade and entry.term is term
    return entry.courses
  []

addPin = (grade, term, id) !->
  for entry in state.profile.pinned when entry.grade is grade and entry.term is term
    entry.courses.push id unless id in entry.courses
    changed!
    return
  state.profile.pinned.push { grade: grade, term: term, courses: [id] }
  changed!

removePin = (grade, term, id) !->
  kept = []
  for entry in state.profile.pinned
    if entry.grade is grade and entry.term is term
      entry.courses = [c for c in entry.courses when c isnt id]
    kept.push entry if entry.courses.length > 0
  state.profile.pinned = kept
  changed!

pinnedTerm = (id) ->
  for entry in state.profile.pinned when id in entry.courses
    return entry
  null

# --- reset, export, import -------------------------------------------------

reset = !->
  state.profile = emptyProfile!
  changed!

# The engine reads plain lists; dump them in the same order the example
# profiles use so an exported file reads like a hand-written one.
toYaml = ->
  p = state.profile
  out = {}
  for key, value of p when key not in KNOWN
    out[key] = value
  out = out <<< {
    completed: p.completed
    preHsCompleted: p.preHsCompleted
    inProgress: p.inProgress
    pinned: p.pinned
    waivers: p.waivers
    optionalTerms: p.optionalTerms
    rigor: p.rigor
    interests: p.interests
    objective: p.objective
  }
  out.goal = p.goal if p.goal and p.goal.length
  out.maxCoursesPerTerm = p.maxCoursesPerTerm if p.maxCoursesPerTerm?
  yaml.dump out, { lineWidth: 72, noRefs: true }

fromYaml = (text) ->
  parsed = yaml.load text
  throw new Error 'that does not look like a profile' unless parsed? and typeof parsed is 'object'
  state.profile = normalize parsed
  changed!

module.exports = {
  load, save, subscribe, changed, profile, schoolId, ui, setSchool, setUi,
  setField, has, add, remove, toggle, setStanding, standingOf, STANDING,
  pinKey, pinsFor, addPin, removePin, pinnedTerm, reset, toYaml, fromYaml,
  emptyProfile
}
