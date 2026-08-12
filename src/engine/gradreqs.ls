# Graduation-requirement coverage. Each requirement carries a
# satisfied_by predicate and its own credit target; coverage is tracked
# per requirement id. Covering every requirement by the final term is a
# hard rule: search steers toward it and drops plans that miss it when
# any plan covers it.

# Predicate forms, all data:
#   satisfied_by: { tag: english }                    any course with the tag
#   satisfied_by: { courses: [ENG2003A, ENG2003B] }   an explicit id list
#   satisfied_by: { content: [english9_a, english9_b] }  content groups, so
#     placement variants (honors / AP / EML tiers) all satisfy the slot
#   satisfied_by: { any: [pred, pred] }   alternatives, e.g. a content
#     group or the partner college's approved stand-ins
matchPred = (sb, course) ->
  # grad_tags, when present, are the district's own word on what a
  # course earns credit as (a partner college's approved list); plain
  # tags carry subject vocabulary for search and interests, which must
  # not satisfy graduation requirements by accident
  return sb.tag in (course.grad_tags or course.tags or []) if sb.tag?
  return course.id in sb.courses if sb.courses?
  return course.content? and course.content in sb.content if sb.content?
  if sb.any?
    for alt in sb.any
      return true if matchPred alt, course
    return false
  false

reqMatches = (req, course) -> matchPred (req.satisfied_by or {}), course

# Credits a course contributes toward each matching requirement. A
# merged college course carries grad_credits, the partner's fixed HS
# graduation credit, distinct from the college credits it banks.
addCourseCredits = (coverage, course, reqs) ->
  credit = if course.grad_credits? then course.grad_credits else (course.credits or 0)
  for req in reqs when reqMatches req, course
    coverage[req.id] = (coverage[req.id] or 0) + credit
  coverage

# Coverage the student starts with. Pre-grade-9 courses count only where
# the school's pre_hs_credit policy grants graduation credit; they satisfy
# prerequisites regardless (that part is handled in dag.initialDone).
initialCoverage = (school, profile, courses) ->
  reqs = school.grad_requirements or []
  coverage = {}
  countable = (profile.completed or []) ++ (profile.inProgress or [])
  if school.pre_hs_credit?.counts_toward_grad
    countable = countable ++ (profile.preHsCompleted or [])
  for id in countable
    course = courses[id]
    addCourseCredits coverage, course, reqs if course?
  coverage

# Total credits still missing across all requirements.
creditsRemaining = (school, coverage) ->
  missing = 0
  for req in (school.grad_requirements or [])
    have = coverage[req.id] or 0
    have = req.credits if have > req.credits
    missing += req.credits - have
  missing

# Requirements that still need credit. The search boosts candidates
# matching one of these so filler never crowds out requirement courses.
unmetReqs = (school, coverage) ->
  unmet = []
  for req in (school.grad_requirements or [])
    unmet.push req if (coverage[req.id] or 0) < req.credits
  unmet

module.exports = { reqMatches, addCourseCredits, initialCoverage, creditsRemaining, unmetReqs }
