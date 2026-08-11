# Term-by-term beam search over feasible per-term course subsets.
# Feasibility is symbolic and absolute; the soft scorer downstream only
# reorders what survives here. Deterministic: identical inputs always
# produce identical plans (stable sorts, lexicographic tiebreaks).

{ prereqsMet, prereqIds } = require './dag'
{ addCourseCredits, initialCoverage, creditsRemaining, unmetTags } = require './gradreqs'

# Built-in tuning; weights/engine.yaml carries the same values and wins
# when passed in (search options.tuning). Tune there, not here.
DEFAULT_TUNING =
  search: { beam: 100, topK: 14, subsets: 40, keepPlans: 20 }
  objective: { gradWeight: 20, eagernessScale: 0.0001 }
  priority: {
    requirement: 40, continuation: 5, interest: 2, goal: 4,
    usefulBanked: 2, unlocks: 0.5, banked: 4, rigor: 3, eagerRigor: 2
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
# has no embeddings or the profile no goal.
goalAffinity = (model, course) ->
  vec = model.embeddings?.courses?[course.id]
  return 0 unless model.goalVec? and vec?
  cosine model.goalVec, vec

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
usefulBanked = (model, id, remaining) ->
  return 0 if remaining <= 0
  key = "#{id}:#{remaining}"
  return model.bankedMemo[key] if model.bankedMemo[key]?
  course = model.courses[id]
  return 0 unless course?
  best = 0
  for dep in (model.forward[id] or [])
    chain = usefulBanked model, dep, remaining - 1
    best := chain if chain > best
  value = (estBanked course, model.levels, model.exams) + best
  model.bankedMemo[key] = value
  value

priorityFor = (model, course, unmet, prevTerm, remaining) ->
  w = model.tuning.priority
  reqBonus = 0
  for tag in (course.tags or []) when unmet.has tag
    reqBonus := w.requirement
  continuation = 0
  for id in (prereqIds course) when prevTerm.has id
    continuation := w.continuation
  interestBonus = 0
  for tag in (course.tags or []) when model.interests.has tag
    interestBonus := w.interest
  reqBonus + continuation + interestBonus +
    w.goal * (goalAffinity model, course) +
    w.usefulBanked * (usefulBanked model, course.id, remaining) +
    w.unlocks * (model.unlocks[course.id] or 0) +
    w.banked * (estBanked course, model.levels, model.exams) +
    w.rigor * (rigorAffinity model, course)

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

# A course is available in a term when the term's own offerings list
# names it, the term is open, or the course's offered_terms match.
offeredIn = (course, term) ->
  return course.id in term.offerings if term.offerings?
  term.open or term.term in (course.offered_terms or [])

# Every course that is legal in this term for this state. Hard rules,
# with one opening for real-world exceptions: a waiver stands in for a
# course's prerequisites.
candidatesFor = (model, state, term) ->
  out = []
  for id, course of model.courses
    continue if state.done.has id
    continue if duplicatesContent course, state
    continue unless offeredIn course, term
    continue unless term.grade in (course.grade_levels or [])
    continue unless model.waivers.has(id) or prereqsMet course, state.done
    out.push course
  out

# Among candidates that conflict (same content group or an excludes
# pair), keep only the variant closest to the student's rigor target.
# Without this, a longer variant chain (2YR Algebra 2) outranks the
# intense one via critical-path urgency, which inverts the preference.
filterVariants = (model, candidates) ->
  keep = []
  for c in candidates
    dominated = false
    for other in candidates
      continue if other.id is c.id
      conflict = (c.content? and other.content is c.content) or
                 (other.id in (c.excludes or [])) or
                 (c.id in (other.excludes or []))
      continue unless conflict
      mine = rigorAffinity model, c
      theirs = rigorAffinity model, other
      # ties break toward the variant banking more credit (BC over AB),
      # then by id for determinism
      myBank = estBanked c, model.levels, model.exams
      theirBank = estBanked other, model.levels, model.exams
      if theirs > mine or
         (theirs is mine and theirBank > myBank) or
         (theirs is mine and theirBank is myBank and other.id < c.id)
        dominated := true
        break
    keep.push c unless dominated
  keep

rankCandidates = (model, candidates, unmet, prevTerm, remaining) ->
  candidates.sort (a, b) ->
    diff = (priorityFor model, b, unmet, prevTerm, remaining) - (priorityFor model, a, unmet, prevTerm, remaining)
    if diff isnt 0 then diff else (if a.id < b.id then -1 else 1)
  candidates

# Pins are overrides: the student knows about exceptions the engine
# cannot. A pinned course is always scheduled; a school rule it breaks
# becomes a warning to check with a counselor, never a refusal. Only a
# pin that cannot mean anything (unknown id, already taken) is skipped.
resolvePins = (model, state, term, pinnedIds, warnings) ->
  placed = []
  key = "#{term.grade}:#{term.term}"
  for id in pinnedIds
    course = model.courses[id]
    if not course?
      warnings.add "pin #{id} in #{key}: unknown course id, cannot schedule"
    else if state.done.has id
      warnings.add "pin #{id} in #{key}: already taken, skipped"
    else
      legal = (offeredIn course, term) and
              (term.grade in (course.grade_levels or [])) and
              (model.waivers.has(id) or prereqsMet course, state.done)
      unless legal
        warnings.add "pin #{id} in #{key}: overrides a school rule; kept, check with a counselor"
      placed.push course
  placed

subsetCredits = (chosen) ->
  total = 0
  for course in chosen
    total += course.credits or 0
  total

# The course cap counts class periods: a double-period course
# (periods: 2) consumes two slots.
subsetPeriods = (chosen) ->
  total = 0
  for course in chosen
    total += course.periods or 1
  total

fitsCaps = (chosen, course, caps) ->
  return false if caps.courses? and subsetPeriods(chosen) + (course.periods or 1) > caps.courses
  return false if caps.credits? and subsetCredits(chosen) + (course.credits or 0) > caps.credits
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
# included. Include-first DFS so maximal subsets are generated first;
# bounded at maxN to keep expansion cost fixed.
enumSubsets = (ranked, caps, pinned, maxN) ->
  results = []
  explore = (i, chosen) ->
    return if results.length >= maxN
    if i >= ranked.length
      results.push chosen.slice!
      return
    if (fitsCaps chosen, ranked[i], caps) and not conflictsWithChosen ranked[i], chosen
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
  {
    done: model.done0
    contentTaken: contentTaken
    excluded: excluded
    plan: []
    banked: 0
    coverage: initialCoverage model.school, model.profile, model.courses
  }

# One search state extended by one term's course subset.
successorState = (model, state, term, subset) ->
  done = new Set(state.done)
  contentTaken = new Set(state.contentTaken)
  excluded = new Set(state.excluded)
  coverage = {} <<< state.coverage
  banked = state.banked
  ids = []
  for course in subset
    done.add course.id
    contentTaken.add course.content if course.content?
    for e in (course.excludes or [])
      excluded.add e
    addCourseCredits coverage, course
    banked += estBanked course, model.levels, model.exams
    ids.push course.id
  ids.sort!
  {
    done: done
    contentTaken: contentTaken
    excluded: excluded
    coverage: coverage
    banked: banked
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
  total = 0
  for entry, i in state.plan
    weight = 0
    for id in entry.courses
      course = model.courses[id]
      continue unless course?
      affinity = rigorAffinity model, course
      weight += (1 + (model.unlocks[id] or 0) + affinityWeight * affinity) * (course.credits or 0)
    total += (horizon - i) * weight
  total * model.tuning.objective.eagernessScale

# Symbolic objective. Missing graduation credit is penalized in every
# objective so requirement courses always dominate electives.
objectiveScore = (model, state, objective) ->
  missing = creditsRemaining model.school, state.coverage
  base = state.banked   # max_credits and default
  if objective is 'early_grad'
    base = if missing is 0 then 1000 - state.plan.length else 0
  base - model.tuning.objective.gradWeight * missing + eagerness model, state

planSignature = (state) ->
  parts = []
  for entry in state.plan
    parts.push "#{entry.grade}:#{entry.term}=#{entry.courses.join ','}"
  parts.join ';'

# --- beam ------------------------------------------------------------------

scoreAndPrune = (model, states, objective, beamWidth) ->
  for state in states
    state.g = objectiveScore model, state, objective
    state.sig = planSignature state
  states.sort (a, b) ->
    diff = b.g - a.g
    if diff isnt 0 then diff else (if a.sig < b.sig then -1 else 1)
  states.slice 0, beamWidth

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
# candidate for each unrepresented unmet tag is injected anyway (health
# is offered in one grade; missing the window fails graduation).
injectUnmetTags = (ranked, candidates, unmet, pinnedIds) ->
  represented = new Set!
  for c in ranked
    for tag in (c.tags or [])
      represented.add tag
  for tag in Array.from(unmet) when not represented.has tag
    for c in candidates when tag in (c.tags or []) and c.id not in pinnedIds
      ranked.push c unless c in ranked
      break
  ranked

expandState = (model, state, term, pinnedIds, caps, params, warnings) ->
  pinned = resolvePins model, state, term, pinnedIds, warnings
  candidates = filterVariants model, candidatesFor(model, state, term)
  unmet = unmetTags model.school, state.coverage
  remaining = model.terms.length - term.index
  rankCandidates model, candidates, unmet, previousTermCourses(state), remaining
  ranked = [c for c in candidates.slice(0, params.topK) when c.id not in pinnedIds]
  injectUnmetTags ranked, candidates, unmet, pinnedIds
  effCaps = caps
  if term.maxCourses?
    limit = if caps.courses? then Math.min(caps.courses, term.maxCourses) else term.maxCourses
    effCaps = { courses: limit, credits: caps.credits }
  successors = []
  for subset in enumSubsets ranked, effCaps, pinned, params.subsets
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
  covered.slice 0, keep

minDefined = (a, b) ->
  return Math.min a, b if a? and b?
  if a? then a else b

loadCaps = (model) ->
  {
    courses: minDefined model.school.max_courses_per_term, model.profile.maxCoursesPerTerm
    credits: model.school.max_credits_per_term
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
      for next in expandState model, state, term, pinnedIds, caps, params, warnings
        successors.push next
    beam = scoreAndPrune model, successors, objective, params.beam
  plans = collectPlans model, beam, params.keepPlans, warnings
  { plans: plans, warnings: Array.from(warnings), objective: objective }

module.exports = { search, estBanked, courseIntensity, targetIntensity, rigorAffinity, cosine, goalAffinity }
