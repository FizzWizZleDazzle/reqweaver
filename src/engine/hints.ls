# Advisory hints: cheap counterfactual probes comparing the returned
# plans against nearby profile changes the student could make. A hint
# never changes a plan; it is a suggestion with a measured delta ("summer
# school would bank about 6 more credits"), so the student decides.

{ buildModel } = require './dag'
{ search, courseIntensity, targetIntensity } = require './search'

# Credit-weighted mean intensity of a plan, on the registry scale.
planIntensity = (model, state) ->
  total = 0
  credits = 0
  for entry in state.plan
    for id in entry.courses
      course = model.courses[id]
      continue unless course?
      total += (courseIntensity course, model.levels) * (course.credits or 0)
      credits += course.credits or 0
  if credits > 0 then total / credits else 0

allOptionalTerms = (school) ->
  opts = []
  for grade in school.grade_levels
    for slot in (school.terms_per_year or []) when slot.optional
      opts.push "#{grade}:#{slot.id}"
  opts

# Re-solve with every optional term opted in (narrow beam; this is an
# estimate) and report what the student would gain.
summerHint = (model, best, options) ->
  available = allOptionalTerms model.school
  missing = [t for t in available when t not in (model.profile.optionalTerms or [])]
  return null unless missing.length
  probeProfile = JSON.parse JSON.stringify model.profile
  probeProfile.optionalTerms = available
  probeModel = buildModel model.school, probeProfile, model.levels, model.exams
  probeModel.embeddings = model.embeddings
  probeModel.goalVec = model.goalVec
  probe = search probeModel, { beam: 40, tuning: (options or {}).tuning }
  pbest = probe.plans[0]
  return null unless pbest?
  covered = best.gradRemaining - pbest.gradRemaining
  gained = pbest.banked - best.banked
  if covered > 0
    "opting into summer school (#{missing.join ', '}) covers #{covered} more graduation credits"
  else if gained >= 2
    "opting into summer school (#{missing.join ', '}) could bank about #{gained} more college credits"
  else
    null

# The plan runs below the rigor the student asked for, usually because
# prerequisite standing forces the gentler track first.
rigorHint = (model, best) ->
  rigor = if model.profile.rigor? then model.profile.rigor else 0.5
  return null unless rigor >= 0.6
  target = targetIntensity model.profile
  actual = planIntensity model, best
  return null unless target - actual > 0.5
  "the plan averages intensity #{actual.toFixed 1} against your rigor target
 #{target.toFixed 1}; summer school, a placement waiver, or pinning the
 intense variants can catch the track you want sooner".replace /\n /g, ''

# Unused periods the student could spend on interests or keep free.
capacityHint = (model, best) ->
  free = 0
  for entry, i in best.plan
    cap = model.terms[i]?.maxCourses or model.school.max_courses_per_term
    continue unless cap?
    used = 0
    for id in entry.courses
      used += model.courses[id]?.periods or 1
    free += cap - used if cap > used
  return null unless free >= 4
  "the plan leaves about #{free} periods open; state interests or a goal to
 fill them with courses you care about, or keep them as off periods".replace /\n /g, ''

hints = (model, result, options) ->
  best = result.plans[0]
  return [] unless best?
  out = []
  for hint in [summerHint(model, best, options), rigorHint(model, best), capacityHint(model, best)]
    out.push hint if hint?
  out

module.exports = { hints, planIntensity }
