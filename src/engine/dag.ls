# Graph construction and hard-rule checks. Everything downstream (search,
# scoring) consumes the model built here; nothing may bypass these checks.

# Unroll the school's terms_per_year calendar over its grade span.
# Optional terms join only where the profile opts in ("<grade>:<termId>").
unrollTerms = (school, profile) ->
  optIns = new Set(profile.optionalTerms or [])
  calendar = (school.terms_per_year or []).slice!
  calendar.sort (a, b) -> a.sequence - b.sequence
  terms = []
  for grade in school.grade_levels
    for slot in calendar
      continue if slot.optional and not optIns.has "#{grade}:#{slot.id}"
      terms.push {
        grade: grade
        term: slot.id
        optional: !!slot.optional
        # A term entry may carry its own course list: `offerings` limits
        # the term to those ids (summer school's select original-credit
        # list); `any_offering` opens the term to every course, flagged
        # for verification. max_courses caps that term alone.
        open: !!slot.any_offering
        offerings: slot.offerings
        maxCourses: slot.max_courses
      }
  for t, i in terms
    t.index = i
  terms

# Prerequisite expressions. The compact form (prereqs.all_of plus
# one-level any_of groups) covers most catalogs. For the rest, a course
# may carry `requires`, a recursive boolean tree:
#   requires: { any: [A, { all: [C, { any: [B, D] }] }] }   # a or (c and (b or d))
# A string leaf means "that course is done"; {all: [...]} and {any: [...]}
# nest arbitrarily. When `requires` is present it replaces `prereqs`.
# A leaf is satisfied by the named course, or by any done course sharing
# its content group: a catalog line reading "Prerequisite: English 11"
# resolves to one variant's id, but AP Language is the same slot, so the
# equivalence map (built in buildModel) makes every variant count.
evalRequires = (node, done, equiv) ->
  if typeof node is 'string'
    return true if done.has node
    for alt in ((equiv or {})[node] or [])
      return true if done.has alt
    return false
  if node.all?
    for child in node.all
      return false unless evalRequires child, done, equiv
    return true
  if node.any?
    for child in node.any
      return true if evalRequires child, done, equiv
    return false
  true   # an empty node constrains nothing

requiresIds = (node) ->
  return [node] if typeof node is 'string'
  ids = []
  for child in ((node.all or []) ++ (node.any or []))
    ids = ids ++ requiresIds child
  ids

# Normalize either prereq form to one tree.
requirementTree = (course) ->
  return course.requires if course.requires?
  p = course.prereqs or {}
  parts = []
  for id in (p.all_of or [])
    parts.push id
  for group in (p.any_of or [])
    parts.push { any: (if Array.isArray group then group else [group]) }
  { all: parts }

prereqsMet = (course, done, equiv) -> evalRequires (requirementTree course), done, equiv

# id -> other course ids sharing its content group.
contentEquivalents = (courses) ->
  members = {}
  for id, course of courses when course.content?
    (members[course.content] ?= []).push id
  equiv = {}
  for group, ids of members
    for id in ids
      equiv[id] = [other for other in ids when other isnt id]
  equiv

# All course ids a course's prerequisites mention, either form.
prereqIds = (course) -> requiresIds (requirementTree course)

# prereq -> dependents adjacency. Unlock edges are always derived from
# prereqs, never stored in specsheets (storing both invites contradiction).
forwardEdges = (courses) ->
  edges = {}
  for id, course of courses
    for dep in prereqIds course when courses[dep]?
      (edges[dep] ?= []).push id
  edges

# Reachable-descendant count per course: how much a course unlocks.
# This is the gateway value the search uses to clear required-by-many
# courses early.
computeUnlocks = (courses) ->
  edges = forwardEdges courses
  memo = {}
  reachable = (id, visiting) ->
    return memo[id] if memo[id]?
    return new Set! if visiting.has id   # cycle guard; CI forbids cycles
    visiting.add id
    found = new Set!
    for next in (edges[id] or [])
      found.add next
      for transitive in Array.from(reachable next, visiting)
        found.add transitive
    visiting.delete id
    memo[id] = found
    found
  counts = {}
  for id of courses
    counts[id] = reachable(id, new Set!).size
  counts

# Longest downstream prerequisite chain per course. A long chain means the
# course must land early or its descendants fall out of the horizon.
computeCritPath = (courses) ->
  edges = forwardEdges courses
  memo = {}
  depth = (id, visiting) ->
    return memo[id] if memo[id]?
    return 0 if visiting.has id
    visiting.add id
    longest = 0
    for next in (edges[id] or [])
      candidate = 1 + depth next, visiting
      longest := candidate if candidate > longest
    visiting.delete id
    memo[id] = longest
    longest
  depths = {}
  for id of courses
    depths[id] = depth id, new Set!
  depths

# Courses the student holds before planning starts. preHsCompleted always
# satisfies prerequisites; whether it also earns graduation credit is the
# school's pre_hs_credit policy, applied in gradreqs.
initialDone = (profile) ->
  done = new Set!
  for field in ['completed', 'preHsCompleted', 'inProgress']
    for id in (profile[field] or [])
      done.add id
  done

# The model: everything the search needs, computed once per profile.
# waivers lists courses whose prerequisites the school has excused for
# this student (placement test, teacher recommendation, ...). exams is
# the exam registry (per-exam credit estimates).
buildModel = (school, profile, levels, exams) ->
  courses = {}
  for course in (school.courses or [])
    courses[course.id] = course
  {
    school: school
    profile: profile
    levels: levels
    exams: exams or {}
    courses: courses
    terms: unrollTerms school, profile
    done0: initialDone profile
    waivers: new Set(profile.waivers or [])
    avoid: new Set(profile.avoid or [])
    interests: new Set(profile.interests or [])
    unlocks: computeUnlocks courses
    critPath: computeCritPath courses
    forward: forwardEdges courses
    contentEquiv: contentEquivalents courses
    bankedMemo: {}
    # semantic layer, attached by the caller when precomputed
    # embeddings exist for this school (see tools/embed.py)
    embeddings: null
    goalVec: null
  }

module.exports = { buildModel, prereqsMet, prereqIds, unrollTerms, forwardEdges, contentEquivalents }
