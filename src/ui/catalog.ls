# Read-only views over a school specsheet: lookups, the term calendar, the
# tag vocabulary, and prerequisite trees in a shape the UI can render.
# Nothing here decides feasibility; the engine owns that.

{ forwardEdges } = require '../engine/dag'

index = (school, extra) ->
  byId = {}
  list = []
  for course in (school.courses or [])
    byId[course.id] = course
    list.push course
  # merged partner-college courses; school ids win a collision, like the
  # engine's merge
  for course in (extra or []) when not byId[course.id]?
    byId[course.id] = course
    list.push course
  list.sort (a, b) -> if a.id < b.id then -1 else 1
  { byId: byId, list: list, dependents: forwardEdges byId }

# The partner college's approved courses as the engine plans them (see
# dag.ls mergeColleges, which this mirrors for display): each carries
# the college id, the partner's fixed HS graduation credit, the grade
# window from the partner's minimum grade, and the college's optional
# terms unless the course is term-restricted.
collegeCourses = (school, partner, sheet) ->
  gradCredit = if partner.grad_credit_per_course? then partner.grad_credit_per_course else 1.0
  minGrade = partner.min_grade_level
  grades = [g for g in (school.grade_levels or []) when not minGrade? or g >= minGrade]
  regular = [t.id for t in (sheet.terms_per_year or []) when not t.optional]
  extra = [t.id for t in (sheet.terms_per_year or []) when t.optional]
  out = []
  for course in (sheet.courses or []) when course.approved
    clone = {} <<< course
    clone.college = partner.college
    clone.grad_credits = gradCredit
    clone.grade_levels = grades
    clone.offered_terms = (course.offered_terms or []).slice!
    restricted = false
    for t in regular when t not in clone.offered_terms
      restricted := true
    unless restricted
      clone.offered_terms = clone.offered_terms ++ extra
    out.push clone
  out

# Every tag the catalog uses, so the interest picker offers the school's
# own vocabulary rather than a hard-coded list.
tags = (school) ->
  seen = {}
  for course in (school.courses or [])
    for tag in (course.tags or [])
      seen[tag] = true
  Object.keys(seen).sort!

# The calendar unrolled over the grade span, optional terms included. The
# engine drops the optional ones the student did not opt into; the UI needs
# them all so it can offer the opt-in.
termSlots = (school) ->
  calendar = (school.terms_per_year or []).slice!
  calendar.sort (a, b) -> a.sequence - b.sequence
  slots = []
  for grade in (school.grade_levels or [])
    for slot in calendar
      slots.push {
        grade: grade
        term: slot.id
        optional: !!slot.optional
        open: !!slot.any_offering
        key: "#{grade}:#{slot.id}"
        label: "Grade #{grade} #{slot.id}"
      }
  slots

termIds = (school) ->
  calendar = (school.terms_per_year or []).slice!
  calendar.sort (a, b) -> a.sequence - b.sequence
  [slot.id for slot in calendar]

# --- prerequisites ---------------------------------------------------------

# Mirrors the engine's normalization (dag.ls requirementTree) for display:
# either the compact prereqs form or a recursive requires tree becomes one
# nested { all: [...] } / { any: [...] } structure.
requirementTree = (course) ->
  return course.requires if course.requires?
  p = course.prereqs or {}
  parts = []
  for id in (p.all_of or [])
    parts.push id
  for group in (p.any_of or [])
    parts.push { any: (if Array.isArray group then group else [group]) }
  { all: parts }

isEmptyTree = (node) ->
  return false if typeof node is 'string'
  return true unless node?
  children = (node.all or []) ++ (node.any or [])
  return true if children.length is 0
  for child in children
    return false unless isEmptyTree child
  true

hasPrereqs = (course) -> not isEmptyTree requirementTree course

# --- course search ---------------------------------------------------------

# Filter-as-you-type over a few hundred courses: every whitespace-separated
# term must appear in the id or the name. Exact id prefixes rank first.
filter = (list, query, limit) ->
  q = (query or '').trim!.toLowerCase!
  return list.slice 0, limit unless q.length
  words = [w for w in q.split /\s+/ when w.length]
  hits = []
  for course in list
    haystack = "#{course.id} #{course.name}".toLowerCase!
    ok = true
    for w in words
      unless haystack.indexOf(w) >= 0
        ok = false
        break
    continue unless ok
    rank = if course.id.toLowerCase!.indexOf(words[0]) is 0 then 0 else 1
    hits.push { course: course, rank: rank }
  hits.sort (a, b) ->
    diff = a.rank - b.rank
    if diff isnt 0 then diff else (if a.course.id < b.course.id then -1 else 1)
  [h.course for h in hits.slice 0, limit]

# --- display helpers -------------------------------------------------------

levelOf = (course) -> course.level or 'regular'

# What a level means comes from registry/levels.yaml, never from its name.
levelNote = (levels, course) ->
  attrs = (levels or {})[levelOf course] or {}
  notes = []
  notes.push 'banks college credit directly' if attrs.college_credit
  notes.push 'targets a registry exam' if attrs.exam_bearing
  notes.join ', '

creditsLabel = (value) ->
  n = value or 0
  if n is Math.round n then "#{n}.0" else String n

module.exports = {
  index, collegeCourses, tags, termSlots, termIds, requirementTree,
  hasPrereqs, filter, levelOf, levelNote, creditsLabel
}
