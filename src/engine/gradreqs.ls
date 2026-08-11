# Graduation-requirement coverage. Coverage is tracked per tag as earned
# credits; a requirement is met when its tag has accumulated its credit
# target. Covering all requirements by the final term is a hard rule:
# search steers toward it and drops plans that miss it when any plan
# covers it.

# Credits a course contributes toward each of its tags.
addCourseCredits = (coverage, course) ->
  for tag in (course.tags or [])
    coverage[tag] = (coverage[tag] or 0) + (course.credits or 0)
  coverage

# Coverage the student starts with. Pre-grade-9 courses count only where
# the school's pre_hs_credit policy grants graduation credit; they satisfy
# prerequisites regardless (that part is handled in dag.initialDone).
initialCoverage = (school, profile, courses) ->
  coverage = {}
  countable = (profile.completed or []) ++ (profile.inProgress or [])
  if school.pre_hs_credit?.counts_toward_grad
    countable = countable ++ (profile.preHsCompleted or [])
  for id in countable
    course = courses[id]
    addCourseCredits coverage, course if course?
  coverage

# Total credits still missing across all requirements.
creditsRemaining = (school, coverage) ->
  missing = 0
  for req in (school.grad_requirements or [])
    tag = req.satisfied_by?.tag
    have = if tag? then (coverage[tag] or 0) else 0
    have = req.credits if have > req.credits
    missing += req.credits - have
  missing

# Tags that still have an unmet requirement. The search boosts candidate
# courses carrying one of these tags so electives never crowd out
# requirement courses.
unmetTags = (school, coverage) ->
  tags = new Set!
  for req in (school.grad_requirements or [])
    tag = req.satisfied_by?.tag
    continue unless tag?
    tags.add tag if (coverage[tag] or 0) < req.credits
  tags

module.exports = { addCourseCredits, initialCoverage, creditsRemaining, unmetTags }
