# Validation of a hand-built plan. The manual drag-and-drop planner is
# the primary surface: the student places courses into terms and every
# rule the search enforces comes back here as an issue to display, never
# a refusal. Waivers and the pre-HS record apply the same way they do in
# search; same-term courses never satisfy each other's prerequisites.

{ prereqsMet, offeredIn, pairSlots } = require './dag'
{ addCourseCredits, initialCoverage, creditsRemaining } = require './gradreqs'

minDefined = (a, b) ->
  return Math.min a, b if a? and b?
  if a? then a else b

# One issue per violated rule per placement. kind is stable vocabulary
# for the UI: unknown | duplicate | term | offering | grade | prereq |
# conflict | capacity. Capacity issues carry course: null (they belong
# to the term, not one course).
issue = (entry, id, kind, detail) ->
  { grade: entry.grade, term: entry.term, course: id, kind: kind, detail: detail }

# Seed the taken/content/excluded sets from the courses the student
# already holds, mirroring the search's initial state.
seedTaken = (model) ->
  done = new Set(model.done0)
  contentTaken = new Set!
  excluded = new Set!
  for id in Array.from(model.done0)
    course = model.courses[id]
    continue unless course?
    contentTaken.add course.content if course.content?
    for e in (course.excludes or [])
      excluded.add e
  { done, contentTaken, excluded }

# Rule checks for one course placed in one term. Returns nothing; every
# violation lands in issues. prereqDone is the taken set plus, in a
# sequential term, the term's own courses (sessions run consecutively,
# so B may follow A within the term).
checkPlacement = (model, taken, chosen, entry, term, course, issues, prereqDone) ->
  id = course.id
  if not term?
    issues.push issue(entry, id, 'term', "#{entry.grade}:#{entry.term} is not in the calendar for this profile")
  else
    unless offeredIn course, term
      issues.push issue(entry, id, 'offering', "not offered in #{entry.term}")
    unless entry.grade in (course.grade_levels or [])
      issues.push issue(entry, id, 'grade', "not open to grade #{entry.grade}")
  unless model.waivers.has(id) or prereqsMet course, prereqDone, model.contentEquiv
    issues.push issue(entry, id, 'prereq', 'prerequisites not met by earlier terms')
  if course.content? and taken.contentTaken.has course.content
    issues.push issue(entry, id, 'conflict', 'repeats content already taken')
  if taken.excluded.has id
    issues.push issue(entry, id, 'conflict', 'excluded by a course already taken')
  for other in (course.excludes or []) when taken.done.has other
    issues.push issue(entry, id, 'conflict', "excludes #{other}, already taken")
  for other in chosen
    if course.content? and other.content is course.content
      issues.push issue(entry, id, 'conflict', "same content as #{other.id} this term")
    if (id in (other.excludes or [])) or (other.id in (course.excludes or []))
      issues.push issue(entry, id, 'conflict', "excluded pair with #{other.id} this term")

# The full report for a plan of {grade, term, courses} entries, in any
# order (they are checked in calendar order). Returns issues plus the
# graduation-requirement tracker the planner sidebar renders.
validate = (model, plan) ->
  issues = []
  termsByKey = {}
  for t in model.terms
    termsByKey["#{t.grade}:#{t.term}"] = t
  taken = seedTaken model
  coverage = initialCoverage model.school, model.profile, model.courses
  capCourses = minDefined model.school.max_courses_per_term, model.profile.maxCoursesPerTerm
  capCredits = model.school.max_credits_per_term
  # a partner's max_courses_per_term is a hard cap only when the sheet
  # declares one; funded_per_term is the allowance the district pays
  # for, and exceeding it is an out-of-pocket note, not a violation
  hardBy = {}
  fundedBy = {}
  collegeName = {}
  for partner in ((model.school.dual_enrollment or {}).partners or [])
    hardBy[partner.college] = partner.max_courses_per_term if partner.max_courses_per_term?
    fundedBy[partner.college] = partner.funded_per_term if partner.funded_per_term?
    collegeName[partner.college] = (model.colleges[partner.college] or {}).name or partner.college
  entries = (plan or []).slice!
  entries.sort (a, b) ->
    ta = termsByKey["#{a.grade}:#{a.term}"]
    tb = termsByKey["#{b.grade}:#{b.term}"]
    ia = if ta? then ta.index else 1e9
    ib = if tb? then tb.index else 1e9
    ia - ib
  for entry in entries
    term = termsByKey["#{entry.grade}:#{entry.term}"]
    prereqDone = taken.done
    if term? and term.sequential
      prereqDone = new Set(taken.done)
      for id in (entry.courses or []) when model.courses[id]?
        prereqDone.add id
    chosen = []
    for id in (entry.courses or [])
      course = model.courses[id]
      if not course?
        issues.push issue(entry, id, 'unknown', 'unknown course id')
        continue
      repeat = false
      for other in chosen when other.id is id
        repeat := true
      if repeat
        issues.push issue(entry, id, 'duplicate', 'listed twice in this term')
        continue
      if taken.done.has id
        issues.push issue(entry, id, 'duplicate', 'already taken in an earlier term')
      checkPlacement model, taken, chosen, entry, term, course, issues, prereqDone
      chosen.push course
    # school caps bind school courses; in a sequential (summer school)
    # term a college course is not summer school at all, and everywhere
    # a college course counts its fixed HS grad credit, not its college
    # credits. The partner's own per-term course cap binds separately.
    schoolChosen = [c for c in chosen when not c.college?]
    counted = if term? and term.sequential then schoolChosen else chosen
    periods = 0
    credits = 0
    for course in counted
      periods += course.periods or 1
      credits += if course.grad_credits? then course.grad_credits else (course.credits or 0)
    if term? and term.sequential
      periods = pairSlots [c.id for c in schoolChosen], model.pairA
    capHere = capCourses
    if term? and term.maxCourses?
      capHere = minDefined capHere, term.maxCourses
    creditCap = capCredits
    if term? and term.maxCredits?
      creditCap = minDefined creditCap, term.maxCredits
    if capHere? and periods > capHere
      issues.push issue(entry, null, 'capacity', "#{periods} periods over the #{capHere}-period cap")
    if creditCap? and credits > creditCap
      issues.push issue(entry, null, 'capacity', "#{credits} credits over the #{creditCap}-credit cap")
    collegeCounts = {}
    for c in chosen when c.college?
      collegeCounts[c.college] = (collegeCounts[c.college] or 0) + 1
    for college, n of collegeCounts
      label = collegeName[college] or college
      if hardBy[college]? and n > hardBy[college]
        issues.push issue(entry, null, 'capacity', "#{n} courses at #{label} over its #{hardBy[college]}-per-term cap")
      else if fundedBy[college]? and n > fundedBy[college]
        issues.push issue(entry, null, 'cost', "#{n} courses at #{label}: #{fundedBy[college]} per term are funded, the rest are out of pocket")
    for course in chosen
      taken.done.add course.id
      taken.contentTaken.add course.content if course.content?
      for e in (course.excludes or [])
        taken.excluded.add e
      addCourseCredits coverage, course, (model.school.grad_requirements or [])
  requirements = []
  for req in (model.school.grad_requirements or [])
    have = coverage[req.id] or 0
    have = req.credits if have > req.credits
    requirements.push { id: req.id, label: req.label, need: req.credits, have: have }
  {
    issues: issues
    requirements: requirements
    remaining: creditsRemaining model.school, coverage
    coverage: coverage
  }

module.exports = { validate }
