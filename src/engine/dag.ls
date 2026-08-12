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
        # for verification. max_courses caps that term alone. A
        # `sequential` term runs its sessions one after another, so a
        # course may follow its prerequisite within the term and an A/B
        # pair fills a single course slot.
        open: !!slot.any_offering
        offerings: slot.offerings
        maxCourses: slot.max_courses
        maxCredits: slot.max_credits
        sequential: !!slot.sequential
      }
  for t, i in terms
    t.index = i
  terms

# A course is available in a term when the term's own offerings list
# names it, the term is open, or the course's offered_terms match. A
# term's offerings list is the school's own (summer school's select
# courses); a partner college's course follows the college calendar
# instead, so dual enrollment stays open during an allowlisted summer.
offeredIn = (course, term) ->
  if term.offerings? and not course.college?
    return course.id in term.offerings
  term.open or term.term in (course.offered_terms or [])

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

# A/B halves of a year course: B's only prerequisite is A and the ids
# differ only in the trailing letter. Derived from the catalog, like the
# UI's pair linking, never stored in specsheets.
derivePairs = (courses) ->
  pairA = {}   # B id -> its A half
  pairB = {}   # A id -> its B half
  for id, course of courses
    ids = prereqIds course
    continue unless ids.length is 1
    a = ids[0]
    continue unless courses[a]?
    continue unless id.length is a.length and id.length > 1
    stemMatch = id.slice(0, id.length - 1) is a.slice(0, a.length - 1)
    if stemMatch and a.slice(-1) is 'A' and id.slice(-1) is 'B'
      pairA[id] = a
      pairB[a] = id
  { pairA, pairB }

# Course slots a set of ids occupies where both halves of an A/B pair
# together fill one slot (a sequential summer compresses a year course
# into one session pair).
pairSlots = (ids, pairA) ->
  present = new Set(ids)
  slots = 0
  for id in ids
    a = (pairA or {})[id]
    continue if a? and present.has a   # the B half rides with its A
    slots += 1
  slots

# Courses the student holds before planning starts. preHsCompleted always
# satisfies prerequisites; whether it also earns graduation credit is the
# school's pre_hs_credit policy, applied in gradreqs.
initialDone = (profile) ->
  done = new Set!
  for field in ['completed', 'preHsCompleted', 'inProgress']
    for id in (profile[field] or [])
      done.add id
  done

# Dual enrollment: fold a partner's approved courses into the course
# map when the profile opts in. A partner is any sheet the school
# names, a community college, a university, another high school; the
# profile's dualEnrollment is true (all partners) or a list of partner
# ids. Each merged course banks its own credits but contributes the
# partner's fixed graduation credit (MCPS grants 1.0 HS credit per
# approved course), opens at the partner's minimum grade, and, when
# the partner runs optional terms (summer sessions) and the course is
# not term-restricted, is offered in those too. School ids win a
# collision.
optedInto = (profile, partner) ->
  opted = profile.dualEnrollment
  return false unless opted
  return true if opted is true
  Array.isArray(opted) and partner.college in opted

mergeColleges = (school, profile, courses, colleges) ->
  for partner in ((school.dual_enrollment or {}).partners or [])
    continue unless optedInto profile, partner
    sheet = (colleges or {})[partner.college]
    continue unless sheet?
    gradCredit = if partner.grad_credit_per_course? then partner.grad_credit_per_course else 1.0
    minGrade = partner.min_grade_level
    grades = [g for g in school.grade_levels when not minGrade? or g >= minGrade]
    regular = [t.id for t in (sheet.terms_per_year or []) when not t.optional]
    extra = [t.id for t in (sheet.terms_per_year or []) when t.optional]
    for course in (sheet.courses or [])
      continue unless course.approved
      continue if courses[course.id]?
      clone = {} <<< course
      clone.college = partner.college
      clone.grad_credits = gradCredit
      clone.grade_levels = grades
      # a college course takes more of the school day than one class
      # period: at the default weight, five college courses fill a
      # seven-period day completely
      clone.periods = if partner.period_weight? then partner.period_weight else 1.4
      clone.offered_terms = (course.offered_terms or []).slice!
      restricted = false
      for t in regular when t not in clone.offered_terms
        restricted := true
      unless restricted
        clone.offered_terms = clone.offered_terms ++ extra
      courses[course.id] = clone

# A college course carrying exam_equivalent duplicates a school AP
# course's material: the pair may not both earn credit (mutual
# excludes, which also lets the variant filter prefer the AP course),
# and either satisfies a prerequisite naming the other, with a warning
# downstream because the school may not honor the swap.
linkExamEquivalents = (courses, equiv) ->
  byExam = {}
  apTwins = {}
  for id, course of courses when course.exam? and not course.college?
    (byExam[course.exam] ?= []).push id
  for id, course of courses when course.college? and course.exam_equivalent?
    for exam in course.exam_equivalent
      for schoolId in (byExam[exam] or [])
        (apTwins[id] ?= []).push schoolId
        continue if course.excludes? and schoolId in course.excludes
        course.excludes = (course.excludes or []) ++ [schoolId]
        sc = courses[schoolId]
        courses[schoolId] = {} <<< sc <<< { excludes: (sc.excludes or []) ++ [id] }
        (equiv[schoolId] ?= []).push id
        (equiv[id] ?= []).push schoolId
  apTwins

# The model: everything the search needs, computed once per profile.
# waivers lists courses whose prerequisites the school has excused for
# this student (placement test, teacher recommendation, ...). exams is
# the exam registry (per-exam credit estimates). colleges maps partner
# sheet ids to loaded college sheets; merging is gated on the
# profile's dualEnrollment opt-in.
buildModel = (school, profile, levels, exams, colleges) ->
  courses = {}
  for course in (school.courses or [])
    courses[course.id] = course
  mergeColleges school, profile, courses, colleges
  done0 = initialDone profile
  done0Tags = new Set!
  for id in Array.from(done0)
    for tag in (courses[id]?.tags or [])
      done0Tags.add tag
  pairs = derivePairs courses
  contentEquiv = contentEquivalents courses
  apTwins = linkExamEquivalents courses, contentEquiv
  {
    apTwins: apTwins
    pairA: pairs.pairA
    pairB: pairs.pairB
    colleges: colleges or {}
    school: school
    profile: profile
    levels: levels
    exams: exams or {}
    courses: courses
    terms: unrollTerms school, profile
    done0: done0
    done0Tags: done0Tags
    waivers: new Set(profile.waivers or [])
    avoid: new Set(profile.avoid or [])
    interests: new Set(profile.interests or [])
    unlocks: computeUnlocks courses
    critPath: computeCritPath courses
    forward: forwardEdges courses
    contentEquiv: contentEquiv
    bankedMemo: {}
    # semantic layer, attached by the caller when precomputed
    # embeddings exist for this school (see tools/embed.py)
    embeddings: null
    goalVec: null
  }

module.exports = { buildModel, prereqsMet, prereqIds, unrollTerms, forwardEdges, contentEquivalents, offeredIn, derivePairs, pairSlots }
