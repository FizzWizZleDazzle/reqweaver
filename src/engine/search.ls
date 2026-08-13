# Term-by-term beam search over feasible per-term course subsets.
# Feasibility is symbolic and absolute; the soft scorer downstream only
# reorders what survives here. Deterministic: identical inputs always
# produce identical plans (stable sorts, lexicographic tiebreaks).

{ prereqsMet, prereqIds, offeredIn, pairSlots } = require './dag'
{ reqMatches, addCourseCredits, initialCoverage, creditsRemaining, unmetReqs } = require './gradreqs'

# Built-in tuning; weights/engine.yaml carries the same values and wins
# when passed in (search options.tuning). Tune there, not here.
DEFAULT_TUNING =
  # collegeFullLoad: college courses a full-rigor student carries per
  # term; scaled by the profile's rigor (four college classes alone is
  # about a 0.9 appetite)
  search: { beam: 100, topK: 14, subsets: 40, keepPlans: 20, collegeFullLoad: 5 }
  # dedication: credits earned by advancing an already-started chain
  # (its prerequisite is behind the student), scaled by goal alignment
  # and zeroed by dislikes, weighted above what the same slot banks as
  # an interchangeable elective. Multi-year commitment is worth more
  # to an application than farmed credit.
  # outOfPocket: objective cost per college course past the partner's
  # funded allowance in one term; the family pays for those, so one
  # must earn its keep against real value, not fill a slot
  objective: { gradWeight: 20, eagernessScale: 0.0001, dedication: 4, outOfPocket: 12 }
  priority: {
    requirement: 40, continuation: 5, familyContinuation: 10, interest: 2, goal: 12,
    usefulBanked: 2, unlocks: 0.5, banked: 4, rigor: 3, eagerRigor: 2,
    newSequence: 6, pairGap: 3, collegeFiller: 15, goalBank: 6,
    goalStrong: 0.5, ladder: 2
  }

mergeTuning = (given) ->
  merged = {}
  for section, defaults of DEFAULT_TUNING
    merged[section] = {} <<< defaults <<< ((given or {})[section] or {})
  merged

# --- per-course values -----------------------------------------------------

# Banked-credit estimate. College courses (dual enrollment) bank their own
# credits directly. Exam-bearing courses bank a half-course share of the
# exam registry's credit estimate (so AP Calculus BC outvalues AB); real
# articulation comes from a major specsheet, until then this is the
# labeled fallback.
estBanked = (course, levels, exams) ->
  level = levels[course.level or 'regular'] or {}
  return course.credits or 0 if level.college_credit
  return 0 unless course.exam and level.exam_bearing
  ((exams or {})[course.exam] or (exams or {}).default or 3) / 2

courseIntensity = (course, levels) ->
  level = levels[course.level or 'regular'] or {}
  level.intensity or 1

# Cosine over pre-normalized embedding vectors (see tools/embed.py).
cosine = (a, b) ->
  return 0 unless a? and b?
  s = 0
  for v, i in a
    s += v * (b[i] or 0)
  s

# Semantic closeness of a course to the student's stated free-text goal,
# via precomputed description embeddings. Zero (inert) when the school
# has no embeddings or the profile no goal. Centered against the
# catalog's mean cosine: sentence-embedding cosines cluster in a narrow
# band (any two course descriptions sit near 0.6), so the raw value
# barely separates on-topic from off-topic and banked credit steamrolls
# it; centered, an off-topic course scores negative and the goal weight
# means what it says.
goalStats = (model) ->
  return model.goalStatsMemo if model.goalStatsMemo?
  total = 0
  n = 0
  best = -1
  for id, course of model.courses
    vec = model.embeddings?.courses?[id]
    continue unless vec?
    c = cosine model.goalVec, vec
    total += c
    n += 1
    best := c if c > best
  mean = if n > 0 then total / n else 0
  model.goalStatsMemo = { mean: mean, top: (if best > mean then best - mean else 0) }
  model.goalStatsMemo

goalMean = (model) -> (goalStats model).mean

# Strong alignment: within reach of the catalog's best match for this
# goal. Being merely above the mean is a low bar (the mean includes
# gym and nursing), and a paid dual-enrollment slot should not clear
# it on lexical overlap alone (a Photoshop course mentions software;
# it is not software engineering).
goalStrongBar = (model) ->
  frac = model.tuning?.priority?.goalStrong
  frac = 0.5 unless frac?
  frac * (goalStats model).top

goalAffinity = (model, course) ->
  vec = model.embeddings?.courses?[course.id]
  return 0 unless model.goalVec? and vec?
  (cosine model.goalVec, vec) - goalMean model

# The intensity tier the student is aiming for. rigor is a 0..1 profile
# preference: 0 prefers regular-track variants, 1 prefers the most intense
# variant whose prerequisites allow it. Maps onto the registry's intensity
# scale (regular 1 .. ap/ib 3).
targetIntensity = (profile) ->
  rigor = if profile.rigor? then profile.rigor else 0.5
  1 + 2 * rigor

# How well a course matches the student's rigor target, in [0, 1].
rigorAffinity = (model, course) ->
  gap = Math.abs (courseIntensity course, model.levels) - targetIntensity model.profile
  1 - Math.min(gap, 2) / 2

# Candidate ordering within a term. Requirement courses outrank electives
# (the unmet-tag bonus), then continuation of a just-started sequence (a
# B half chases its A half instead of dangling for a year), critical-path
# urgency, unlock value, banked-credit yield, and closeness to the
# student's rigor target (which picks between variants of the same
# content, e.g. 2YR vs honors Algebra 2).
# Banked credit reachable by starting this course now with `remaining`
# terms left, following its steepest prerequisite chain one course per
# term. Replaces raw chain depth as the urgency signal: a chain that
# cannot reach its payoff inside the horizon (French 1 in grade 11
# aiming at an AP four years away) is worth nothing.
usefulBanked = (model, id, remaining, done) ->
  return 0 if remaining <= 0
  memo = if done? then (done.usefulMemo ?= {}) else model.bankedMemo
  key = "#{id}:#{remaining}"
  return memo[key] if memo[key]?
  course = model.courses[id]
  return 0 unless course?
  best = 0
  # the chain stays in its subject: a statistics course "reaching"
  # college biology credit through a math-readiness prerequisite is
  # a phantom chain, not a ladder this course opens. And it counts
  # only what this course marginally unlocks: a dependent already
  # takeable from what the student holds does not need it, so a prep
  # course must not resell the credit of an AP that was reachable
  # without it.
  for dep in (model.forward[id] or [])
    depCourse = model.courses[dep]
    continue unless depCourse? and sharesSubject model, depCourse, id
    continue if done? and prereqsMet depCourse, done, model.contentEquiv
    chain = usefulBanked model, dep, remaining - 1, done
    best := chain if chain > best
  value = (estBanked course, model.levels, model.exams) + best
  memo[key] = value
  value

# State-independent per-course values, computed once per model: the
# goal cosine alone is a 384-dimension dot product, and ranking calls
# these for every candidate in every state in every term.
staticScores = (model, course) ->
  model.staticScore ?= {}
  hit = model.staticScore[course.id]
  return hit if hit?
  preIds = prereqIds course
  model.staticScore[course.id] = {
    goal: goalAffinity model, course
    banked: estBanked course, model.levels, model.exams
    rigorAff: rigorAffinity model, course
    preIds: preIds
    root: preIds.length is 0 and (model.unlocks[course.id] or 0) >= 1
  }

# A sequence root is a course with no prerequisites that opens a chain
# (even a two-course ladder: Elementary Arabic II makes Elementary
# Arabic I a root). Starting a second sequence in a tag family the
# student is already partway through (Chinese 1 alongside Spanish, or
# with Spanish 1-3 already on record) is penalized: continuity beats
# breadth. The requirement bonus dwarfs the penalty, so a root that
# covers an unmet graduation requirement is never suppressed.
isSequenceRoot = (model, course) ->
  (prereqIds course).length is 0 and (model.unlocks[course.id] or 0) >= 1

# A prerequisite carries chain lineage only when it teaches the same
# subject: Spanish 4 continues Spanish 3, Multivariable continues
# Calculus II. A math placement bar in front of a biology course is
# readiness, not lineage; without this, holding AP Statistics made
# "Principles of Biology" read as continuation. A prerequisite the
# catalog names but the sheet does not carry is trusted to be the
# same subject.
sharesSubject = (model, course, preId) ->
  pre = model.courses[preId]
  return true unless pre?
  for tag in (course.tags or []) when tag in (pre.tags or [])
    return true
  false

priorityFor = (model, course, unmet, prevTerm, remaining, doneTags, hasBonus, done) ->
  w = model.tuning.priority
  # the requirement bonus is granted by rankCandidates to just enough
  # top candidates to cover each requirement's remaining need; giving
  # it to every matcher stacked four same-requirement courses into one
  # term
  reqBonus = if hasBonus then w.requirement else 0
  fixed = staticScores model, course
  # continuation of a started family is a value of its own, stronger
  # than the last-term chase: a student three years into Spanish gets
  # Spanish 4 over an interchangeable AP elective, which is worth more
  # than its credits (continuity is what colleges read)
  continuation = 0
  for id in fixed.preIds when sharesSubject model, course, id
    if prevTerm.has id
      continuation := Math.max continuation, w.continuation
    else if done? and doneOrEquivalent model, id, done
      continuation := Math.max continuation, w.familyContinuation
  interestBonus = 0
  for tag in (course.tags or []) when model.interests.has tag
    interestBonus := w.interest
  # A root opened in a family already underway loses its unlock reward
  # too: on a real catalog a language chain unlocks more than any flat
  # penalty, so the penalty alone cannot hold the line.
  rootPenalty = 0
  secondFamily = false
  if fixed.root
    for tag in (course.tags or []) when doneTags.has tag
      # the full strip: penalty, unlock reward, and the rigor pull (a
      # college-level second language otherwise outranks free school
      # electives on intensity alone)
      rootPenalty := w.newSequence + w.unlocks * (model.unlocks[course.id] or 0) + w.rigor * fixed.rigorAff
      secondFamily := true
  # under early_grad, banked credit is only the objective's tie-break;
  # letting it drive candidate ranking starves the subset enumeration
  # of requirement-diverse combinations (the cap explores ranking
  # prefixes), which hides the earliest covering plans
  bankedScale = if model.objective is 'early_grad' then 0 else 1
  # dual enrollment is for continuing past the school's ceiling or
  # covering a requirement, not for farming credit sideways: a
  # college course that neither serves a requirement nor earns
  # dedication (a ladder of the student's own, advanced at or above
  # their frontier) is paid filler. Filler loses its banked-credit
  # attraction (the credit is exactly why it would otherwise win)
  # and takes a penalty, so it ranks below a plain school elective.
  ladder = if done? then dedicationValue model, course, done else 0
  collegeFiller = 0
  if course.college? and reqBonus is 0 and ladder <= 0
    collegeFiller = w.collegeFiller
    bankedScale = 0
  # a second-family root also loses its banked attraction: with no
  # goal stated, banked credit was re-buying Elementary Arabic past
  # the continuity penalty
  bankedScale = 0 if secondFamily and reqBonus is 0
  # a disliked subject covers its requirement with the lightest
  # sufficient course: the rigor pull inverts (light beats intense),
  # banked credit stops attracting AP variants of it, and without a
  # requirement to serve it takes the filler penalty
  dislikePull = 0
  if hasDislikedTag model, course
    bankedScale = 0
    dislikePull = w.rigor * ((courseIntensity course, model.levels) - 1)
    dislikePull += w.collegeFiller if reqBonus is 0
  # with a stated goal, banked credit is worth more when it aligns:
  # otherwise a 4-credit off-topic course out-points a 3-credit course
  # in the student's field, and alignment never beats raw quantity
  align = 1
  if model.goalVec?
    align = Math.max 0.25, 1 + w.goalBank * fixed.goal
  # the ladder term ranks continuation by how high it climbs: the
  # course at the top of a five-year chain outranks a two-course
  # branch, which is what sends a post-BC student to Multivariable
  # rather than a third parallel statistics variant
  reqBonus + continuation + interestBonus - rootPenalty - collegeFiller - dislikePull +
    w.ladder * ladder +
    w.goal * fixed.goal +
    align * bankedScale * w.usefulBanked * (usefulBanked model, course.id, remaining, done) +
    w.unlocks * (model.unlocks[course.id] or 0) +
    align * bankedScale * w.banked * fixed.banked +
    w.rigor * fixed.rigorAff

# --- per-term candidate handling -------------------------------------------

# True when taking this course would duplicate content the state already
# holds: its `content` group is taken, another course explicitly excluded
# it, or it explicitly excludes a course already taken. `excludes` covers
# the shapes content groups cannot (2YR Algebra 2 A/B vs the one-year
# variants, where a prereq chain forbids a shared group); it is symmetric.
duplicatesContent = (course, state) ->
  return true if course.content? and state.contentTaken.has course.content
  return true if state.excluded.has course.id
  for other in (course.excludes or []) when state.done.has other
    return true
  false

# Every course that is legal in this term for this state. Hard rules,
# with one opening for real-world exceptions: a waiver stands in for a
# course's prerequisites.
# Optimistic terms-to-takeable for a course given what is done: 0 when
# its prerequisites are already met, else one term per chain link along
# the easiest branch. Optimistic on purpose: it feeds the AP-fallback
# rule below, and overestimating reachability suppresses the college
# counterpart more, which is the stated preference.
unmetDepth = (model, id, done, guard) ->
  return 0 if done.has id
  course = model.courses[id]
  return 0 unless course?
  return 0 if prereqsMet course, done, model.contentEquiv
  guard ?= new Set!
  return 9 if guard.has id
  guard.add id
  best = 9
  for pid in (staticScores model, course).preIds
    d = unmetDepth model, pid, done, guard
    best := d if d < best
  guard.delete id
  1 + best

# The AP course is the preferred way to earn its material's credit
# (free, and its exam credit transfers almost everywhere); the college
# counterpart is the fallback. So the counterpart is only admissible
# once no remaining term can still hold the AP twin. A dragged-out or
# already-taken twin does not block, and a pin always overrides.
apStillReachable = (model, state, term, twinId) ->
  return false if state.done.has twinId
  return false if model.avoid.has twinId
  twin = model.courses[twinId]
  return false unless twin?
  depth = unmetDepth model, twinId, state.done
  for t in model.terms when t.index >= term.index
    continue unless t.grade in (twin.grade_levels or [])
    continue unless offeredIn twin, t
    return true if t.index - term.index >= depth
  false

hasDislikedTag = (model, course) ->
  for tag in (course.tags or []) when model.dislikes.has tag
    return true
  false

# A prerequisite counts as behind the student when they hold it or any
# content-equivalent of it: AP Calculus BC stands in for the college
# MATH182, so Multivariable Calculus continues that chain.
doneOrEquivalent = (model, id, done) ->
  return true if done.has id
  for alt in ((model.contentEquiv or {})[id] or []) when done.has alt
    return true
  false

# The courses the student holds in a tag family, with their heights.
# Memoized on the done set itself, which is shared across every
# candidate ranked against one state.
familyHolds = (model, done, tag) ->
  done.frontierMemo ?= {}
  hit = done.frontierMemo[tag]
  return hit if hit?
  holds = []
  for id in Array.from(done)
    course = model.courses[id]
    continue unless course? and tag in (course.tags or [])
    holds.push [course, model.chainDepth[id] or 1]
  done.frontierMemo[tag] = holds
  holds

# Two courses branching from the same prerequisite base are siblings:
# AP Spanish Language and AP Spanish Literature both follow Spanish 5,
# the two Physics C halves both follow Physics 1. Taking one must not
# raise the bar over the other, or only a doubled year could ever hold
# both.
sharesBase = (model, a, b) ->
  pa = (staticScores model, a).preIds
  pb = (staticScores model, b).preIds
  for id in pa
    return true if id in pb
    for alt in ((model.contentEquiv or {})[id] or []) when alt in pb
      return true
  false

# How high the student already stands in the family, as seen from one
# course: the tallest held course that is not its sibling.
familyFrontier = (model, done, tag, course) ->
  top = 0
  for [held, d] in familyHolds model, done, tag
    continue if sharesBase model, course, held
    top = d if d > top
  top

# The dedication a course earns when taken: it advances a ladder the
# student already stands on (a prerequisite is behind them), in a
# subject they have not disliked, higher than they have yet climbed,
# scaled by how well it aligns with the stated goal and the student's
# rigor target. The climb test separates continuation from a sideways
# or backward move: a Precalculus student picking up a lighter
# terminal statistics course is not advancing anything, whatever its
# prerequisites say. And the ladder must be one of the student's own:
# a family they arrived with, an interest they stated, or one that
# leads where their goal points. Anything else the plan starts is the
# engine's invention, and rewarding it as commitment let a music
# theory chain bootstrap itself for a physics student.
dedicationValue = (model, course, done) ->
  fixed = staticScores model, course
  # a disliked course is a strict cost in the objective, or it ties
  # with a neutral elective and wins on the id tie-break; required
  # coverage still dwarfs the charge, so the light variant gets taken,
  # and nothing beyond the requirement does
  return -(schedCredits course) if hasDislikedTag model, course
  onChain = false
  chainTags = []
  # height the student actually climbed to reach this course: its own
  # footprint on top of the tallest completed course satisfying one
  # of its prerequisites, directly or through an equivalent (BC
  # Calculus stands in for the college Calculus II, and its height
  # carries)
  height = 0
  for id in fixed.preIds when sharesSubject model, course, id
    behind = null
    behind = id if done.has id
    unless behind?
      for alt in ((model.contentEquiv or {})[id] or []) when done.has alt
        d = model.chainDepth[alt] or 1
        behind = alt if not behind? or d > (model.chainDepth[behind] or 1)
    continue unless behind?
    onChain := true
    d = model.chainDepth[behind] or 1
    height = d if d > height
    pre = model.courses[id]
    tagPool = if pre? then (pre.tags or []) else (course.tags or [])
    for tag in (course.tags or []) when tag in tagPool and tag not in chainTags
      chainTags.push tag
  return 0 unless onChain
  height += schedCredits course
  # the student's ladder, not the engine's: rooted before the plan,
  # stated as an interest, or strongly goal-aligned
  rooted = fixed.goal >= goalStrongBar model
  unless rooted
    for tag in chainTags when model.done0Tags.has(tag) or model.interests.has(tag)
      rooted := true
  return 0 unless rooted
  # at-or-above the frontier, not strictly above: AP Physics C E/M
  # stands level with Mechanics (parallel branches of one sequence)
  # and continues it; a lighter terminal course stands below and
  # does not
  for tag in chainTags
    return 0 unless height >= familyFrontier model, done, tag, course
  # alignment boosts a chain toward the goal but never starves a
  # school one: three years of Spanish stays dedication for a
  # physics-bound student (colleges read the commitment); only a
  # dislike ends it. A paid college chain is different: continuing
  # it away from the goal is spending, not commitment, so its
  # dedication scales with real alignment like its banked credit.
  align = 1
  if model.goalVec?
    goalBank = model.tuning?.priority?.goalBank or 6
    floor = if course.college? then 0.25 else 1
    align = Math.max floor, 1 + goalBank * fixed.goal
  # rigor tempers it: commitment reads at the student's chosen
  # intensity, and a light terminal course is not the ladder a
  # high-rigor student is climbing (nor an AP chain the ladder of a
  # student who asked for the regular track)
  rigorScale = 0.5 + 0.5 * fixed.rigorAff
  (schedCredits course) * align * rigorScale * height

# A requirement whose school path is still reachable does not hand its
# bonus to a paid college stand-in: the college course is the fallback
# here exactly as it is for AP twins (and early_grad pays for speed,
# so it is exempt at the call site).
schoolPathReachable = (model, state, term, req) ->
  for id, course of model.courses
    continue if course.college?
    continue unless reqMatches req, course
    continue if state.done.has id or model.avoid.has id
    depth = unmetDepth model, id, state.done
    for t in model.terms when t.index >= term.index
      continue unless t.grade in (course.grade_levels or [])
      continue unless offeredIn course, t
      return true if t.index - term.index >= depth
  false

# Availability (offering, grade window, avoid list) is the same for
# every state expanding a term; compute the pool once per term.
eligibleFor = (model, term) ->
  model.termEligible ?= {}
  pool = model.termEligible[term.index]
  return pool if pool?
  pool = []
  for id, course of model.courses
    continue if model.avoid.has id   # dragged out; pins still override
    continue unless offeredIn course, term
    continue unless term.grade in (course.grade_levels or [])
    # placement-restricted tiers (ESOL) serve the students placed into
    # them; they never fill a general student's slot
    restricted = false
    for tag in (course.tags or []) when model.placementGroups.has(tag) and not model.placements.has(tag)
      restricted := true
    continue if restricted
    pool.push course
  model.termEligible[term.index] = pool
  pool

# A year course runs both halves at the first opportunity: once its
# A half is taken in-plan, the B half belongs to the next term that
# can hold it. Optional terms in between (a summer the plan leaves
# empty) do not break the chain, and neither does a term the B half
# could not run in (some catalogs offer Health A in grade 10 and
# Health B in grades 11-12); a term where B was offerable and passed
# untaken does. Halves the student holds from before the plan carry
# no such constraint, and a pin always overrides. Without this, a B
# half dangles for a year and returns as high-priority
# "continuation" filler two grades later.
pairFollowsA = (model, state, aId) ->
  unless model.termInfo?
    model.termInfo = {}
    for t in model.terms
      model.termInfo["#{t.grade}:#{t.term}"] = t
  b = model.courses[(model.pairB or {})[aId]]
  i = state.plan.length - 1
  while i >= 0
    entry = state.plan[i]
    return true if aId in entry.courses
    info = model.termInfo["#{entry.grade}:#{entry.term}"]
    unless info?.optional
      return false if not b?
      return false if (offeredIn b, info) and info.grade in (b.grade_levels or [])
    i -= 1
  false

candidatesFor = (model, state, term) ->
  out = []
  reachable = new Set(state.done)
  pool = eligibleFor model, term
  admit = (doneSet) ->
    grew = false
    for course in pool
      continue if reachable.has course.id
      continue if duplicatesContent course, state
      aId = model.pairA[course.id]
      if aId? and state.done.has(aId) and not model.done0.has(aId)
        continue unless pairFollowsA model, state, aId
      continue unless model.waivers.has(course.id) or prereqsMet course, doneSet, model.contentEquiv
      # under early_grad the student trades the AP course's broader
      # transfer for leaving sooner, so the fallback rule stands down
      if course.college? and model.objective isnt 'early_grad' and (model.apTwins or {})[course.id]?
        blocked = false
        for twinId in model.apTwins[course.id]
          blocked := true if apStillReachable model, state, term, twinId
        continue if blocked
      out.push course
      reachable.add course.id
      grew := true
    grew
  admit state.done
  # a sequential term runs its sessions consecutively, so a course may
  # follow its prerequisite inside the term (summer Algebra 1 A then
  # B); fixpoint because such chains can be longer than two
  if term.sequential
    grew = true
    while grew
      grew = admit reachable
  out

# Among candidates that conflict (same content group or an excludes
# pair), keep only the variant closest to the student's rigor target.
# Without this, a longer variant chain (2YR Algebra 2) outranks the
# intense one via critical-path urgency, which inverts the preference.
# Near-linear: content groups collapse through a best-per-group pass
# and excludes pairs look up only their named ids; the all-pairs scan
# this replaces was quadratic and dominated merged-catalog solves.

# True when a wins the shared slot: an exam-bearing course beats its
# college counterpart (the AP course is free and its exam credit
# transfers more broadly), then rigor affinity, then banked credit
# (BC over AB), then id for determinism. Total order, so a group's
# best is well defined.
beatsInSlot = (model, a, b) ->
  aLevel = model.levels[a.level or 'regular'] or {}
  bLevel = model.levels[b.level or 'regular'] or {}
  return true if aLevel.exam_bearing and bLevel.college_credit
  return false if aLevel.college_credit and bLevel.exam_bearing
  # in a disliked subject the lightest variant wins the slot
  if (hasDislikedTag model, a) and (hasDislikedTag model, b)
    ia = courseIntensity a, model.levels
    ib = courseIntensity b, model.levels
    return true if ia < ib
    return false if ia > ib
  sa = staticScores model, a
  sb = staticScores model, b
  return true if sa.rigorAff > sb.rigorAff
  return false if sa.rigorAff < sb.rigorAff
  return true if sa.banked > sb.banked
  return false if sa.banked < sb.banked
  # among otherwise-equal variants the one topping the taller ladder
  # wins the slot: Linear Algebra over Applications in Linear Algebra
  da = model.chainDepth[a.id] or 1
  db = model.chainDepth[b.id] or 1
  return true if da > db
  return false if da < db
  a.id < b.id

filterVariants = (model, candidates) ->
  byId = {}
  for c in candidates
    byId[c.id] = c
  dominated = new Set!
  groups = {}
  for c in candidates when c.content?
    (groups[c.content] ?= []).push c
  for group, members of groups
    continue unless members.length > 1
    best = members[0]
    for m in members.slice 1
      best := m if beatsInSlot model, m, best
    for m in members when m.id isnt best.id
      dominated.add m.id
  for c in candidates
    for otherId in (c.excludes or [])
      other = byId[otherId]
      continue unless other?
      if beatsInSlot model, other, c
        dominated.add c.id
      else
        dominated.add other.id
  [c for c in candidates when not dominated.has c.id]

bySlotScore = (scored) ->
  scored.sort (a, b) ->
    diff = b.p - a.p
    if diff isnt 0 then diff else (if a.c.id < b.c.id then -1 else 1)
  scored

# Score once per candidate, then sort by the cached score: scoring
# inside the comparator re-evaluates the priority O(n log n) times per
# state, which is what made merged-catalog solves crawl. Ranking runs
# twice: a base pass orders candidates, then each unmet requirement
# grants its bonus to the best matchers up to 1.5x its remaining need,
# and the final pass sorts with the bonuses placed.
rankCandidates = (model, candidates, unmet, prevTerm, remaining, doneTags, coverage, state, term) ->
  done = state?.done
  base = bySlotScore [{ c: c, p: priorityFor model, c, unmet, prevTerm, remaining, doneTags, false, done } for c in candidates]
  marked = new Set!
  for req in unmet
    need = req.credits - ((coverage or {})[req.id] or 0)
    continue unless need > 0
    # marking stops once the marked candidates can cover the need; a
    # marked A half counts its whole year (the B half follows next
    # term), or a full-year requirement marked a redundant second
    # course beside the pair that already covers it
    budget = need - 0.01
    got = 0
    schoolPath = null
    for entry in base when got < budget and reqMatches req, entry.c
      if entry.c.college? and model.objective isnt 'early_grad' and state? and term?
        schoolPath ?= schoolPathReachable model, state, term, req
        continue if schoolPath
      marked.add entry.c.id
      got += if entry.c.grad_credits? then entry.c.grad_credits else (entry.c.credits or 0)
      bHalf = model.pairB[entry.c.id]
      pair = if bHalf? then model.courses[bHalf] else null
      if pair?
        got += if pair.grad_credits? then pair.grad_credits else (pair.credits or 0)
  scored = bySlotScore [{ c: e.c, p: priorityFor model, e.c, unmet, prevTerm, remaining, doneTags, (marked.has e.c.id), done } for e in base]
  [entry.c for entry in scored]

# Pins are overrides: the student knows about exceptions the engine
# cannot. A pinned course is always scheduled; a school rule it breaks
# becomes a warning to check with a counselor, never a refusal. Only a
# pin that cannot mean anything (unknown id, already taken) is skipped.
resolvePins = (model, state, term, pinnedIds, warnings) ->
  placed = []
  key = "#{term.grade}:#{term.term}"
  # in a sequential term, one pin may be another's prerequisite
  doneHere = new Set(state.done)
  if term.sequential
    for id in pinnedIds
      doneHere.add id
  for id in pinnedIds
    course = model.courses[id]
    if not course?
      warnings.add "pin #{id} in #{key}: unknown course id, cannot schedule"
    else if state.done.has id
      warnings.add "pin #{id} in #{key}: already taken, skipped"
    else
      legal = (offeredIn course, term) and
              (term.grade in (course.grade_levels or [])) and
              (model.waivers.has(id) or prereqsMet course, doneHere, model.contentEquiv)
      unless legal
        warnings.add "pin #{id} in #{key}: overrides a school rule; kept, check with a counselor"
      placed.push course
  placed

# Scheduling credit: a merged college course counts its fixed HS
# graduation credit, not its college credits, against school caps.
schedCredits = (course) ->
  if course.grad_credits? then course.grad_credits else (course.credits or 0)

subsetCredits = (chosen) ->
  total = 0
  for course in chosen
    total += schedCredits course
  total

# The course cap counts class periods: a double-period course
# (periods: 2) consumes two slots.
subsetPeriods = (chosen) ->
  total = 0
  for course in chosen
    total += course.periods or 1
  total

# Period charge for a term's mix. School courses cost their own
# periods. College courses cost partner.period_weight each (about one
# period) up to the funded allowance, then period_weight_extra beyond
# it: two college classes fit beside five school periods, but a full
# college load of five fills the day with no room for school courses.
mixedPeriods = (courses, cfgByCollege) ->
  total = 0
  counts = {}
  for c in courses
    if c.college?
      counts[c.college] = (counts[c.college] or 0) + 1
    else
      total += c.periods or 1
  for college, n of counts
    cfg = (cfgByCollege or {})[college] or {}
    w1 = if cfg.weight? then cfg.weight else 1
    w2 = if cfg.weightExtra? then cfg.weightExtra else 5 / 3
    inside = if cfg.funded? then Math.min(n, cfg.funded) else n
    total += inside * w1 + (n - inside) * w2
  total

# seq is set for sequential terms: { done, waivers, equiv, pairA }. In
# those the course cap counts slots where an A/B pair fills one, and
# both the slot and credit caps are the school's summer-school policy,
# so they bind school courses only; a partner college's summer course
# is not school summer school and answers to caps.college, the
# partner's own per-term limit, instead.
fitsCaps = (chosen, course, caps, seq) ->
  if caps.courses?
    if seq?
      unless course.college?
        ids = [c.id for c in chosen when not c.college?] ++ [course.id]
        return false if (pairSlots ids, seq.pairA) > caps.courses
    else
      return false if (mixedPeriods (chosen ++ [course]), caps.collegeCfg) > caps.courses
  if caps.college? and course.college?
    n = 1
    for c in chosen when c.college?
      n += 1
    return false if n > caps.college
  if caps.credits?
    if seq?
      unless course.college?
        total = schedCredits course
        for c in chosen when not c.college?
          total += schedCredits c
        return false if total > caps.credits
    else
      return false if subsetCredits(chosen) + (schedCredits course) > caps.credits
  true

# A subset in a sequential term must be internally consistent: every
# course's prerequisites are met by earlier terms or by the subset
# itself (the candidate fixpoint admits B on the promise of A; the
# promise is checked here).
sequentialOk = (chosen, seq) ->
  return true unless seq?
  ids = new Set(seq.done)
  for c in chosen
    ids.add c.id
  for c in chosen
    return false unless seq.waivers.has(c.id) or prereqsMet c, ids, seq.equiv
  true

# Content exclusion also holds within a single term: two variants of one
# content group, or an excludes pair, never share a subset.
conflictsWithChosen = (course, chosen) ->
  for other in chosen
    return true if course.content? and other.content is course.content
    return true if other.id in (course.excludes or [])
    return true if course.id in (other.excludes or [])
  false

# Feasible subsets of the ranked candidates, pinned courses always
# included. Three families share the budget: for every candidate, a
# greedy subset built around it (so a deep-ranked course the top
# courses would crowd out is still tried somewhere) and one built
# without it (so a top course is somewhere challenged); include-first
# DFS tail variations fill the rest. Pure include-first DFS locked
# the highest-ranked prefix into every subset, and a banked-credit
# heavyweight in that prefix could never lose its seat to a
# lower-ranked course worth more to the whole plan.
enumSubsets = (ranked, caps, pinned, maxN, seq) ->
  results = []
  seen = new Set!
  keep = (subset) ->
    return unless sequentialOk subset, seq
    ids = [c.id for c in subset]
    ids.sort!
    key = ids.join ','
    return if seen.has key
    seen.add key
    results.push subset
  greedy = (seed, skip) ->
    chosen = pinned.slice!
    admit = (course) ->
      return false if course in chosen
      (fitsCaps chosen, course, caps, seq) and not conflictsWithChosen course, chosen
    for course in (seed or [])
      chosen.push course if admit course
    for course, i in ranked
      continue if skip? and i is skip
      chosen.push course if admit course
    chosen
  keep greedy!
  for course, i in ranked
    break if results.length >= maxN
    keep greedy [course]
    keep greedy null, i
  explore = (i, chosen) ->
    return if results.length >= maxN
    if i >= ranked.length
      keep chosen.slice!
      return
    if (fitsCaps chosen, ranked[i], caps, seq) and not conflictsWithChosen ranked[i], chosen
      chosen.push ranked[i]
      explore i + 1, chosen
      chosen.pop!
    explore i + 1, chosen
  explore 0, pinned.slice!
  results

# --- state transitions -----------------------------------------------------

initialState = (model) ->
  contentTaken = new Set!
  excluded = new Set!
  for id in Array.from(model.done0)
    course = model.courses[id]
    continue unless course?
    contentTaken.add course.content if course.content?
    for e in (course.excludes or [])
      excluded.add e
  coverage = initialCoverage model.school, model.profile, model.courses
  {
    done: model.done0
    contentTaken: contentTaken
    excluded: excluded
    plan: []
    banked: 0
    coverage: coverage
    # the first term index at which every graduation requirement is
    # covered; -1 when the profile already covers them all
    coveredAt: if (creditsRemaining model.school, coverage) is 0 then -1 else null
  }

# One search state extended by one term's course subset.
successorState = (model, state, term, subset) ->
  done = new Set(state.done)
  contentTaken = new Set(state.contentTaken)
  excluded = new Set(state.excluded)
  coverage = {} <<< state.coverage
  banked = state.banked
  ids = []
  bankedAligned = state.bankedAligned or 0
  # open A halves are tracked so the beam can kill a state whose B
  # window closes and the final collection can prefer whole pairs;
  # the pair rules make dangling structurally impossible, so the
  # half's value counts as soon as it is taken
  pairPending = {} <<< (state.pairPending or {})
  dw = model.tuning.objective.dedication
  vals = []
  for course in subset
    share = 0
    earned = 0
    # a disliked subject banks nothing: the student will not sit an
    # exam in it, so its credit must not buy the course a slot
    unless hasDislikedTag model, course
      earned = estBanked course, model.levels, model.exams
      # the objective counts credit scaled by goal alignment: credit
      # in the wrong area is not worth the slot it takes (raw banked
      # stays for display)
      scale = 1
      if model.goalVec?
        goalBank = model.tuning?.priority?.goalBank or 6
        scale = Math.max 0.25, 1 + goalBank * (staticScores model, course).goal
      share = earned * scale
    vals.push { course: course, earned: earned, share: share, ded: dedicationValue model, course, state.done }
  # same-term subject saturation: a counselor schedules at most two
  # courses of one subject at once, and the second one at the
  # student's own level (BC beside AP Statistics, not Precalculus
  # beside a regular-track statistics elective). The strongest keeps
  # its value, a level-appropriate second keeps its value, the rest
  # contribute nothing to the objective (a disliked course's charge
  # stands).
  byTag = {}
  for v in vals
    tag = (v.course.tags or [])[0]
    continue unless tag?
    (byTag[tag] ?= []).push v
  for tag, group of byTag when group.length > 1
    group.sort (a, b) -> (b.share + dw * b.ded) - (a.share + dw * a.ded)
    for v, i in group.slice 1
      atLevel = (staticScores model, v.course).rigorAff >= 0.5
      continue if i is 0 and atLevel
      v.share = 0
      v.ded = 0 if v.ded > 0
  # college courses past the partner's funded allowance cost the
  # family real money; the objective charges for each
  cost = state.cost or 0
  unless model.fundedBy?
    model.fundedBy = {}
    for partner in ((model.school.dual_enrollment or {}).partners or [])
      model.fundedBy[partner.college] = partner.funded_per_term if partner.funded_per_term?
  collegeCounts = {}
  for v in vals when v.course.college?
    collegeCounts[v.course.college] = (collegeCounts[v.course.college] or 0) + 1
  for college, n of collegeCounts
    funded = model.fundedBy[college]
    continue unless funded? and n > funded
    cost += (model.tuning.objective.outOfPocket or 0) * (n - funded)
  for v in vals
    course = v.course
    done.add course.id
    contentTaken.add course.content if course.content?
    for e in (course.excludes or [])
      excluded.add e
    addCourseCredits coverage, course, (model.school.grad_requirements or [])
    banked += v.earned
    bankedAligned += v.share
    if model.pairB[course.id]?
      pairPending[course.id] = true
    aHalf = model.pairA[course.id]
    if aHalf? and pairPending[aHalf]?
      delete pairPending[aHalf]
    ids.push course.id
  ids.sort!
  dedication = state.dedication or 0
  for v in vals
    dedication += v.ded
  coveredAt = state.coveredAt
  if not coveredAt? and (creditsRemaining model.school, coverage) is 0
    coveredAt = term.index
  {
    done: done
    contentTaken: contentTaken
    excluded: excluded
    coverage: coverage
    banked: banked
    bankedAligned: bankedAligned
    dedication: dedication
    cost: cost
    pairPending: pairPending
    coveredAt: coveredAt
    plan: state.plan ++ [{ grade: term.grade, term: term.term, courses: ids }]
  }

# --- scoring ---------------------------------------------------------------

# Tie-break term: gateway eagerness (unlock-weighted credits taken early)
# plus rigor affinity, so among plans the objective ties, the one that
# front-loads gateways and matches the student's rigor target wins.
# Scaled far below one credit so it can never override the objective.
eagerness = (model, state) ->
  horizon = model.terms.length
  affinityWeight = model.tuning.priority.eagerRigor
  rootWeight = model.tuning.priority.newSequence
  gapWeight = model.tuning.priority.pairGap
  tagsSoFar = new Set(model.done0Tags)
  seenAt = {}   # course id -> term position, for the pair-gap penalty
  damped = new Set!   # a damped root and its whole downstream chain
  total = 0
  for entry, i in state.plan
    weight = 0
    termTags = new Set!
    termSubjects = new Set!
    for id in entry.courses
      course = model.courses[id]
      continue unless course?
      fixed = staticScores model, course
      affinity = fixed.rigorAff
      # continuity in the tie-break too: a sequence root opened in a
      # family already underway, in an earlier term or earlier in this
      # one, takes the penalty and loses its unlock reward, and so does
      # everything downstream of it. Damping only the root is not
      # enough: each continuation carries its own unlock reward, so a
      # deep second chain recoups a one-time penalty. The damped chain
      # scores like plain filler, no worse, so a deliberately pinned
      # second language still continues.
      contrib = 1 + (model.unlocks[id] or 0) + affinityWeight * affinity
      # a disliked course is tolerated coverage, not a preference the
      # tie-break should reward for intensity
      contrib := 1 if hasDislikedTag model, course
      fromDamped = false
      for pid in fixed.preIds when damped.has pid
        fromDamped := true
      if fromDamped
        damped.add id
        contrib := 1 + affinityWeight * affinity
      else if fixed.root
        for tag in (course.tags or []) when tagsSoFar.has(tag) or termTags.has(tag)
          contrib := 1 + affinityWeight * affinity - rootWeight
          damped.add id
      # A/B halves belong in consecutive terms; every term of
      # separation counts against the plan
      partner = model.pairA[id]
      if partner? and seenAt[partner]?
        gap = i - seenAt[partner] - 1
        contrib := contrib - gapWeight * gap if gap > 0
      # among otherwise-equal plans, one language level per year
      # beats a gap year and a doubled year: the second course of a
      # subject in one term contributes a quarter here, which must
      # undercut what front-loading it a year early would earn
      subject = (course.tags or [])[0]
      if subject?
        contrib := contrib * 0.25 if termSubjects.has subject
        termSubjects.add subject
      # weight by the HS scheduling footprint: a college course's own
      # credit count would let it crowd every half-credit school course
      # out of the tie-break
      weight += contrib * schedCredits course
      seenAt[id] = i
      for tag in (course.tags or [])
        termTags.add tag
    for tag in Array.from(termTags)
      tagsSoFar.add tag
    total += (horizon - i) * weight
  total * model.tuning.objective.eagernessScale

# Graduation credit still schedulable per requirement from each term
# forward, as a suffix sum over the calendar. Static and optimistic
# (it ignores slot competition and conflicts): a requirement only
# draws its full mid-plan penalty once optimism runs out, which is
# exactly when deferring it further must cost.
reqCapacity = (model) ->
  return model.reqCapacityMemo if model.reqCapacityMemo?
  caps = {}
  for req in (model.school.grad_requirements or [])
    per = []
    for term in model.terms
      total = 0
      for id, course of model.courses
        continue unless term.grade in (course.grade_levels or [])
        continue unless offeredIn course, term
        continue unless reqMatches req, course
        total += if course.grad_credits? then course.grad_credits else (course.credits or 0)
      per.push total
    suffix = new Array per.length + 1
    suffix[per.length] = 0
    for i from per.length - 1 to 0 by -1
      suffix[i] = suffix[i + 1] + per[i]
    caps[req.id] = suffix
  model.reqCapacityMemo = caps

# Missing graduation credit, weighted by scarcity: a requirement the
# calendar can still absorb many times over costs almost nothing to
# defer, one whose window is closing costs its full weight. A flat
# per-credit penalty made the beam stuff grade 9 with zero-value
# requirement variants and prune the plans that spent those slots on
# a language ladder whose value compounds for four years, covering
# PE in a summer instead. At the horizon's end capacity is zero and
# the full penalty stands, so plans that never cover still sink.
weightedMissing = (model, state) ->
  caps = reqCapacity model
  at = state.plan.length
  total = 0
  for req in (model.school.grad_requirements or [])
    need = req.credits - (state.coverage[req.id] or 0)
    continue unless need > 0
    capacity = (caps[req.id] or [])[at] or 0
    total += if capacity > 0 then Math.min(need, need * need / capacity) else need
  total

# Symbolic objective. Missing graduation credit is penalized in every
# objective so requirement courses always dominate electives.
objectiveScore = (model, state, objective) ->
  missing = weightedMissing model, state
  # the default objective is dedication plus alignment-scaled credit:
  # raw credit maximization filled slots with wrong-area classes
  # (Fundamentals of Nursing for a software engineer), so credit
  # counts in proportion to where the student is going
  base = (state.bankedAligned or state.banked) + model.tuning.objective.dedication * (state.dedication or 0) - (state.cost or 0)
  if objective is 'early_grad'
    # every term of earlier coverage outweighs anything banked credit
    # can add; banked breaks ties among equally short paths
    base = if state.coveredAt? then 1000 - 200 * state.coveredAt + state.banked else 0
  base - model.tuning.objective.gradWeight * missing + eagerness model, state

planSignature = (state) ->
  parts = []
  for entry in state.plan
    parts.push "#{entry.grade}:#{entry.term}=#{entry.courses.join ','}"
  parts.join ';'

# --- beam ------------------------------------------------------------------

# Which requirements a state still owes; the diversity key below.
reqSignature = (model, state) ->
  parts = [req.id for req in unmetReqs model.school, state.coverage]
  parts.join ','

# States holding the same courses face the same future, whatever order
# the terms took them in: one representative per class is enough. The
# open A halves whose B is still schedulable stay in the signature (a
# pair completable in one layout may be dead in another). Without this
# the beam fills with layout permutations of the same art and PE
# variants, and a plan whose value compounds over years (a language
# ladder ridden to its AP) is crowded out before it pays.
futureSig = (model, state) ->
  unless model.termInfo?
    model.termInfo = {}
    for t in model.terms
      model.termInfo["#{t.grade}:#{t.term}"] = t
  ids = Array.from(state.done)
  ids.sort!
  open = []
  i = state.plan.length - 1
  while i >= 0
    entry = state.plan[i]
    for id in entry.courses
      b = model.pairB[id]
      open.push id if b? and not state.done.has b
    info = model.termInfo?["#{entry.grade}:#{entry.term}"]
    break unless info?.optional
    i -= 1
  open.sort!
  ids.join(',') + '|' + open.join(',') + '|' + String(state.coveredAt ? '')

scoreAndPrune = (model, states, objective, beamWidth) ->
  # a pair whose B-half window has closed can never complete: the A
  # half dangles on the transcript forever, which a counselor would
  # never leave. Such states are dead unless nothing else survives
  # (a pinned lone A half must not empty the beam).
  alive = []
  for state in states
    dead = false
    for aId of (state.pairPending or {})
      dead := true unless pairFollowsA model, state, aId
    alive.push state unless dead
  states = alive if alive.length > 0
  for state in states
    state.g = objectiveScore model, state, objective
    state.sig = planSignature state
  states.sort (a, b) ->
    diff = b.g - a.g
    if diff isnt 0 then diff else (if a.sig < b.sig then -1 else 1)
  # best layout per future-equivalence class; states arrive sorted, so
  # the first of a class is its best
  classes = new Set!
  unique = []
  for state in states
    key = futureSig model, state
    continue if classes.has key
    classes.add key
    unique.push state
  states = unique
  kept = states.slice 0, beamWidth
  # requirement diversity: the best state of every distinct
  # unmet-requirement signature survives the cut. A scarce requirement
  # (one source, two terms) has few pursuers, and pure score ordering
  # crowds them out with higher-coverage states that provably cannot
  # cover earlier. Adds at most a handful of states per term.
  seen = new Set!
  for state in kept
    seen.add reqSignature model, state
  for state in states.slice beamWidth
    key = reqSignature model, state
    continue if seen.has key
    seen.add key
    kept.push state
  kept

# Courses taken in the state's most recent planned term, for the
# continuation bonus.
previousTermCourses = (state) ->
  prev = new Set!
  if state.plan.length > 0
    for id in state.plan[state.plan.length - 1].courses
      prev.add id
  prev

# Guarantee scarce requirement windows stay reachable: when the top-K
# slice is crowded with other requirement-bearing candidates, the best
# candidate for each unrepresented unmet requirement is injected anyway
# (health is offered in one grade; missing the window fails graduation).
injectUnmetReqs = (model, ranked, candidates, unmet, pinnedIds, state, term) ->
  for req in unmet
    represented = false
    for c in ranked when reqMatches req, c
      represented := true
    continue if represented
    for c in candidates when (reqMatches req, c) and c.id not in pinnedIds
      # the injection guarantee must not smuggle a paid college
      # stand-in past the school-path rule: when the school still owns
      # a reachable path to this requirement, only a school course may
      # represent it here
      if c.college? and model.objective isnt 'early_grad' and schoolPathReachable model, state, term, req
        continue
      ranked.push c unless c in ranked
      break
  ranked

expandState = (model, state, term, pinnedIds, caps, params, warnings) ->
  pinned = resolvePins model, state, term, pinnedIds, warnings
  candidates = filterVariants model, candidatesFor(model, state, term)
  unmet = unmetReqs model.school, state.coverage
  remaining = model.terms.length - term.index
  doneTags = new Set!
  for id in Array.from(state.done)
    for tag in (model.courses[id]?.tags or [])
      doneTags.add tag
  candidates = rankCandidates model, candidates, unmet, previousTermCourses(state), remaining, doneTags, state.coverage, state, term
  ranked = [c for c in candidates.slice(0, params.topK) when c.id not in pinnedIds]
  injectUnmetReqs model, ranked, candidates, unmet, pinnedIds, state, term
  effCaps = caps
  if term.maxCourses? or term.maxCredits?
    effCaps = {
      courses: minDefined caps.courses, term.maxCourses
      credits: minDefined caps.credits, term.maxCredits
      college: caps.college
      collegeCfg: caps.collegeCfg
    }
  seq = null
  if term.sequential
    seq = { done: state.done, waivers: model.waivers, equiv: model.contentEquiv, pairA: model.pairA }
  successors = []
  for subset in enumSubsets ranked, effCaps, pinned, params.subsets, seq
    successors.push successorState model, state, term, subset
  successors

# Unique complete plans, best-first. Covering graduation requirements is a
# hard rule: when any surviving plan covers them, plans that do not are
# dropped; when none does, all are kept and a warning says so.
collectPlans = (model, beam, keep, warnings) ->
  seen = new Set!
  unique = []
  for state in beam
    continue if seen.has state.sig
    seen.add state.sig
    state.gradRemaining = creditsRemaining model.school, state.coverage
    unique.push state
  covered = [s for s in unique when s.gradRemaining is 0]
  if covered.length is 0 and unique.length > 0
    warnings.add 'no plan covers all graduation requirements within the horizon'
    covered = unique
  # a finished plan leaves no half-year course dangling: an A half
  # whose B half never lands wasted its slot, and a counselor would
  # strike it
  whole = [s for s in covered when Object.keys(s.pairPending or {}).length is 0]
  covered = whole if whole.length > 0
  kept = covered.slice 0, keep
  # a scheduled college counterpart of an AP course carries two catches
  # the student must hear about
  fundedBy = {}
  nameOf = {}
  for partner in ((model.school.dual_enrollment or {}).partners or [])
    fundedBy[partner.college] = partner.funded_per_term if partner.funded_per_term?
    nameOf[partner.college] = (model.colleges[partner.college] or {}).name or partner.college
  for state in kept
    for entry in state.plan
      counts = {}
      for id in entry.courses
        course = model.courses[id]
        continue unless course? and course.college?
        counts[course.college] = (counts[course.college] or 0) + 1
        if course.exam_equivalent?
          warnings.add "#{id} (#{nameOf[course.college] or course.college}) covers AP course material but does not register you for the AP exam, and school courses that assume the district credit need counselor confirmation"
      # dual enrollment beyond the funded allowance is legal; the
      # family pays for the rest
      for college, n of counts
        funded = fundedBy[college]
        continue unless funded? and n > funded
        warnings.add "#{n} courses at #{nameOf[college] or college} in grade #{entry.grade} #{entry.term}: #{funded} per term are funded, the rest are out of pocket"
  kept

minDefined = (a, b) ->
  return Math.min a, b if a? and b?
  if a? then a else b

loadCaps = (model) ->
  college = null
  partners = (model.school.dual_enrollment or {}).partners or []
  collegeCfg = {}
  for partner in partners
    college = minDefined college, partner.max_courses_per_term
    collegeCfg[partner.college] = {
      funded: partner.funded_per_term
      weight: partner.period_weight
      weightExtra: partner.period_weight_extra
    }
  # college courses are a heavier load than their period count shows;
  # how many one term can carry follows the rigor appetite
  if partners.length
    rigor = if model.profile.rigor? then model.profile.rigor else 0.5
    full = model.tuning?.search?.collegeFullLoad or 5
    college = minDefined college, Math.max(1, Math.round(full * rigor))
  {
    courses: minDefined model.school.max_courses_per_term, model.profile.maxCoursesPerTerm
    credits: model.school.max_credits_per_term
    college: college
    collegeCfg: collegeCfg
  }

# Pins grouped per term; several pin entries for one term merge.
pinsByTerm = (profile) ->
  pins = {}
  for pin in (profile.pinned or [])
    key = "#{pin.grade}:#{pin.term}"
    pins[key] = (pins[key] or []) ++ (pin.courses or [])
  pins

search = (model, options) ->
  opts = options or {}
  model.tuning = mergeTuning opts.tuning
  params = {} <<< model.tuning.search
  params.beam = opts.beam if opts.beam?
  objective = model.profile.objective or 'max_credits'
  model.objective = objective
  caps = loadCaps model
  pins = pinsByTerm model.profile
  warnings = new Set!   # deduped; the same pin warning repeats across beam states
  for term in model.terms when term.open or term.offerings?
    warnings.add "#{term.term} offerings change yearly; verify against the school's summer catalog"
  beam = [initialState model]
  for term in model.terms
    pinnedIds = pins["#{term.grade}:#{term.term}"] or []
    successors = []
    for state in beam
      # early graduation means leaving: once a state covers every
      # requirement, its plan ends rather than filling the remaining
      # terms
      if objective is 'early_grad' and state.coveredAt?
        successors.push state
        continue
      for next in expandState model, state, term, pinnedIds, caps, params, warnings
        successors.push next
    beam = scoreAndPrune model, successors, objective, params.beam
  plans = collectPlans model, beam, params.keepPlans, warnings
  { plans: plans, warnings: Array.from(warnings), objective: objective }

module.exports = { search, estBanked, courseIntensity, targetIntensity, rigorAffinity, cosine, goalAffinity, goalStrongBar, eagerness, mergeTuning, mixedPeriods, priorityFor, rankCandidates, staticScores, dedicationValue, candidatesFor, filterVariants, initialState, successorState, objectiveScore, eligibleFor, unmetDepth, expandState, scoreAndPrune, loadCaps }
