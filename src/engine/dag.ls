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
# With an equivalence map, a course also unlocks everything its
# equivalents unlock: AP Physics C E/M stands in for the college
# PHYS262, so the college PHYS263 counts among E/M's dependents. This
# is what separates a chain-continuing AP course from a dead-end one
# when both bank the same exam credit.
forwardEdges = (courses, equiv) ->
  edges = {}
  for id, course of courses
    for dep in prereqIds course when courses[dep]?
      (edges[dep] ?= []).push id
      for alt in ((equiv or {})[dep] or []) when courses[alt]?
        edges[alt] ?= []
        edges[alt].push id unless id in edges[alt]
  edges

# Reachable-descendant count per course: how much a course unlocks.
# This is the gateway value the search uses to clear required-by-many
# courses early.
computeUnlocks = (courses, equiv) ->
  edges = forwardEdges courses, equiv
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

# Height of the prerequisite ladder a course tops, in year-course
# units: each link counts its scheduling footprint (an A or B half is
# half a year, a college course a full one), so a school ladder of
# halves and a college ladder of whole courses measure alike. The
# height follows the requirement tree: required parts take the
# tallest, but an any-of group counts its shortest member, or a
# lower-track alternative prerequisite would let a terminal elective
# measure as tall as the honors ladder beside it. Equivalents stay
# out of the measure: a course's own catalog position is its height,
# and the taller road a particular student arrived by is credited
# dynamically where dedication is computed.
computeChainDepth = (courses) ->
  memo = {}
  footprint = (course) ->
    if course.grad_credits? then course.grad_credits else (course.credits or 1)
  depth = (id, visiting) ->
    return memo[id] if memo[id]?
    course = courses[id]
    return 1 unless course?
    return footprint course if visiting.has id
    visiting.add id
    # a prerequisite the sheet does not list is unknown, not zero: it
    # drops out of the tree rather than making its any-of group free
    node = (n) ->
      if typeof n is 'string'
        return if courses[n]? then depth n, visiting else null
      if n.all?
        most = null
        for child in n.all
          d = node child
          most := d if d? and (not most? or d > most)
        return most
      if n.any?
        least = null
        for child in n.any
          d = node child
          least := d if d? and (not least? or d < least)
        return least
      null
    base = node (requirementTree course)
    visiting.delete id
    memo[id] = (footprint course) + (base or 0)
    memo[id]
  depths = {}
  for id of courses
    depths[id] = depth id, new Set!
  depths

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
    continue unless id.length > 1 and id.slice(-1) is 'B'
    a = id.slice(0, id.length - 1) + 'A'
    continue unless courses[a]?
    # the A half appears among B's prerequisites; B usually also
    # carries the course's own entry prerequisites (Honors Algebra 2 B
    # lists Algebra 1 B and Geometry beside its A half), so demanding
    # A be the only one broke most real pairs
    continue unless a in (prereqIds course)
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
# The equivalence that satisfies a prerequisite runs from completed
# material only: the B half (or a single-id course) stands in for the
# college course, but an A half alone is half the material and stands
# in for nothing, or a student mid-way through AP Physics C E/M
# would already satisfy a college course requiring all of PHYS262.
linkExamEquivalents = (courses, equiv, pairB) ->
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
        (equiv[id] ?= []).push schoolId unless (pairB or {})[schoolId]?
  apTwins

# True when a sits anywhere behind b on the prerequisite graph (or
# the reverse): such a pair is a sequence, not a duplicate.
prereqConnected = (courses, a, b) ->
  reaches = (from, to) ->
    seen = new Set!
    walk = (id) ->
      return false if seen.has id
      seen.add id
      course = courses[id]
      return false unless course?
      for pid in prereqIds course
        return true if pid is to
        return true if walk pid
      false
    walk from
  (reaches a, b) or (reaches b, a)

# Two school courses awarded the same college course by the exam
# equivalency table bank overlapping credit: AP Physics 2 and AP
# Physics C E/M both earn PHYS204, so a student sits one exam or the
# other, not both. Courses connected by a prerequisite path stay
# untouched (AP Calculus AB before BC is a sequence the catalog
# allows, and a B half always follows its A half).
expandSharedTwinExcludes = (courses, apTwins) ->
  for collegeId, twins of apTwins
    for s1, i in twins
      for s2 in twins.slice i + 1
        continue if s1 is s2
        c1 = courses[s1]
        c2 = courses[s2]
        continue unless c1? and c2?
        continue if c1.excludes? and s2 in c1.excludes
        continue if prereqConnected courses, s1, s2
        courses[s1] = {} <<< c1 <<< { excludes: (c1.excludes or []) ++ [s2] }
        courses[s2] = {} <<< c2 <<< { excludes: (c2.excludes or []) ++ [s1] }

# A college catalog's own credit exclusions ("credit may not be earned
# in both MATH 170 and MATH 181") reach the excluded course's AP
# twins: a student holding BC Calculus holds MATH 181's material, so
# MATH 170 is spent for them too. Runs after the twin links, over the
# twin relation only; content groups had their pass earlier.
expandTwinExcludes = (courses, apTwins) ->
  additions = []
  for id, course of courses when course.college? and course.excludes?
    for e in course.excludes when courses[e]?.college?
      for twinId in (apTwins[e] or []) when twinId not in course.excludes
        additions.push [id, twinId]
  for [id, twinId] in additions
    course = courses[id]
    course.excludes = course.excludes ++ [twinId] unless twinId in course.excludes
    sc = courses[twinId]
    unless sc.excludes? and id in sc.excludes
      courses[twinId] = {} <<< sc <<< { excludes: (sc.excludes or []) ++ [id] }

# An exclusion reaches the excluded course's content-equivalents:
# BC Calculus excludes AP Calculus AB, and Calculus with Applications
# is the same slot as AB, so finishing BC must also rule it out;
# without this, plans descend a completed ladder for banked credit.
expandExcludes = (courses, equiv) ->
  for id, course of courses
    continue unless course.excludes?
    extra = []
    for e in course.excludes
      for alt in (equiv[e] or []) when alt isnt id and alt not in course.excludes and alt not in extra
        extra.push alt
    continue unless extra.length
    course.excludes = course.excludes ++ extra
    for alt in extra
      other = courses[alt]
      continue unless other?
      continue if other.excludes? and id in other.excludes
      courses[alt] = {} <<< other <<< { excludes: (other.excludes or []) ++ [id] }

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
  # placement-restricted groups (ESOL/EML tiers): their courses cover
  # the same requirements but only join plans for students in the
  # program, inferred from the student's own course history or set
  # explicitly in the profile. A pin still overrides.
  placementGroups = new Set(school.placement_groups or [])
  placements = new Set(profile.placements or [])
  for id in Array.from(done0)
    for tag in (courses[id]?.tags or []) when placementGroups.has tag
      placements.add tag
  pairs = derivePairs courses
  contentEquiv = contentEquivalents courses
  # excludes propagate over pure content groups only; this must run
  # before the exam-twin links join the equivalence map, or an
  # exclusion walks A -> its college twin -> back to A's own B half
  expandExcludes courses, contentEquiv
  apTwins = linkExamEquivalents courses, contentEquiv, pairs.pairB
  expandTwinExcludes courses, apTwins
  expandSharedTwinExcludes courses, apTwins
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
    # disliked topics still cover their requirements, but with the
    # lightest sufficient variant, never as filler
    dislikes: new Set(profile.dislikes or [])
    placementGroups: placementGroups
    placements: placements
    # unlocks counts catalog edges only: the equivalence-bridged graph
    # (kept for the marginal banked chain) inflates a prep course's
    # descendant count with everything its equivalents' dependents
    # transitively reach
    unlocks: computeUnlocks courses
    critPath: computeCritPath courses
    chainDepth: computeChainDepth courses
    forward: forwardEdges courses, contentEquiv
    contentEquiv: contentEquiv
    bankedMemo: {}
    # semantic layer, attached by the caller when precomputed
    # embeddings exist for this school (see tools/embed.py)
    embeddings: null
    goalVec: null
  }

module.exports = { buildModel, prereqsMet, prereqIds, unrollTerms, forwardEdges, contentEquivalents, offeredIn, derivePairs, pairSlots }
