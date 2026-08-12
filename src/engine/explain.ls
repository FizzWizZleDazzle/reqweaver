# Why each course is in a plan. Every planned course gets the reasons it
# earned its slot and a necessity score; a course with no reason is
# swappable filler the student can drag out for a TA period, an office
# aide slot, or anything they would rather do.

{ prereqIds } = require './dag'
{ reqMatches, initialCoverage } = require './gradreqs'
{ estBanked, goalAffinity } = require './search'

# Marginal requirement attribution: walk the plan in term order and give
# each requirement's missing credits to the first matching courses. A
# course beyond what the requirement still needs earns nothing from it
# (the third art elective is not "required" because the first two
# already covered fine arts).
attributeRequirements = (model, state) ->
  reqs = model.school.grad_requirements or []
  needed = {}
  initial = initialCoverage model.school, model.profile, model.courses
  for req in reqs
    needed[req.id] = Math.max 0, req.credits - (initial[req.id] or 0)
  covers = {}
  for entry in state.plan
    for id in entry.courses
      course = model.courses[id]
      continue unless course?
      # consumption rule: one course satisfies at most one requirement
      for req in reqs when needed[req.id] > 0 and reqMatches req, course
        needed[req.id] = Math.max 0, needed[req.id] - (course.credits or 0)
        covers[id] = req.id
        break
  covers

# Later plan courses whose prerequisites this course (or a variant in
# its content group) satisfies.
prereqDependents = (model, state) ->
  satisfies = {}
  for entry in state.plan
    for id in entry.courses
      group = new Set([id] ++ ((model.contentEquiv or {})[id] or []))
      dependents = []
      for later in state.plan when later.grade > entry.grade or
                                   (later.grade is entry.grade and later isnt entry)
        for lid in later.courses
          lcourse = model.courses[lid]
          continue unless lcourse?
          for pid in prereqIds lcourse when group.has pid
            dependents.push lid
      satisfies[id] = dependents
  satisfies

# reasons: [{kind, detail}] and necessity in [0, 1]; kind is one of
# requirement | prerequisite | banked | goal | interest | none.
explain = (model, state) ->
  covers = attributeRequirements model, state
  dependents = prereqDependents model, state
  out = {}
  for entry in state.plan
    for id in entry.courses
      course = model.courses[id]
      continue unless course?
      reasons = []
      necessity = 0.05
      if covers[id]?
        reasons.push { kind: 'requirement', detail: covers[id] }
        necessity = 1
      if dependents[id]?.length
        reasons.push { kind: 'prerequisite', detail: dependents[id] }
        necessity = Math.max necessity, 0.8
      banked = estBanked course, model.levels, model.exams
      if banked > 0
        reasons.push { kind: 'banked', detail: banked }
        necessity = Math.max necessity, Math.min 0.7, 0.3 + banked / 8
      affinity = goalAffinity model, course
      if affinity > 0.35
        reasons.push { kind: 'goal', detail: affinity }
        necessity = Math.max necessity, 0.3 + 0.4 * affinity
      interested = false
      for tag in (course.tags or []) when model.interests.has tag
        interested := true
      if interested
        reasons.push { kind: 'interest' }
        necessity = Math.max necessity, 0.35
      reasons.push { kind: 'none' } if reasons.length is 0
      out[id] = { reasons: reasons, necessity: necessity }
  out

module.exports = { explain }
