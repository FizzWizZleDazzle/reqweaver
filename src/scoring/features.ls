# Plan feature extraction for the soft scorer. Every feature is computed
# from registry attributes (exam_bearing, intensity) and graph structure,
# never from level, exam, or term names, so they apply to any school.
# All features are normalized to roughly [0, 1].

{ estBanked, courseIntensity, rigorAffinity, goalAffinity } = require '../engine/search'

variance = (values) ->
  return 0 if values.length is 0
  mean = 0
  for v in values
    mean += v
  mean = mean / values.length
  spread = 0
  for v in values
    spread += (v - mean) * (v - mean)
  spread / values.length

# Per-term aggregates the features are built from.
termProfile = (model, entry) ->
  credits = 0
  intensity = 0
  examBearing = 0
  gateway = 0
  for id in entry.courses
    course = model.courses[id]
    continue unless course?
    credits += course.credits or 0
    intensity += courseIntensity(course, model.levels) * (course.credits or 0)
    examBearing += 1 if estBanked(course, model.levels, model.exams) > 0
    gateway += (model.unlocks[id] or 0) * (course.credits or 0)
  { credits, intensity, examBearing, gateway }

# Share of unlock-weighted credits cleared in the first half of the plan.
gatewayFront = (profiles) ->
  half = Math.ceil profiles.length / 2
  early = 0
  total = 0
  for p, i in profiles
    early += p.gateway if i < half
    total += p.gateway
  if total > 0 then early / total else 0

# How light the tail of the plan is, as slack against a nominal full load.
# The tail approximates the final year for any term calendar.
finalYearSlack = (model, state, profiles) ->
  tail = Math.max 1, Math.floor profiles.length / 4
  load = 0
  for entry, i in state.plan
    load += entry.courses.length if i >= profiles.length - tail
  1 - load / Math.max(1, tail * 7)

# Credit share of courses carrying a tag the student cares about
# (profile.interests). Steers free capacity toward the student's goals
# instead of whatever unlock-rich chain happens to rank next. Zero when
# no interests are stated, so the feature is inert by default.
interestMatch = (model, state) ->
  interests = new Set(model.profile.interests or [])
  return 0 if interests.size is 0
  matched = 0
  credits = 0
  for entry in state.plan
    for id in entry.courses
      course = model.courses[id]
      continue unless course?
      credits += course.credits or 0
      hit = false
      for tag in (course.tags or []) when interests.has tag
        hit := true
      matched += course.credits or 0 if hit
  if credits > 0 then matched / credits else 0

# Credit-weighted semantic closeness of the plan to the student's stated
# free-text goal, over precomputed description embeddings. Zero (inert)
# when the school has no embeddings or the profile no goal.
goalMatch = (model, state) ->
  return 0 unless model.goalVec?
  matched = 0
  credits = 0
  for entry in state.plan
    for id in entry.courses
      course = model.courses[id]
      continue unless course?
      matched += (goalAffinity model, course) * (course.credits or 0)
      credits += course.credits or 0
  if credits > 0 then matched / credits else 0

# Credit-weighted average of how closely the plan's courses match the
# student's rigor target.
rigorMatch = (model, state) ->
  weighted = 0
  credits = 0
  for entry in state.plan
    for id in entry.courses
      course = model.courses[id]
      continue unless course?
      weighted += (rigorAffinity model, course) * (course.credits or 0)
      credits += course.credits or 0
  if credits > 0 then weighted / credits else 0

extract = (model, state) ->
  profiles = [termProfile model, entry for entry in state.plan]
  maxExamBearing = 0
  for p in profiles
    maxExamBearing = p.examBearing if p.examBearing > maxExamBearing
  {
    rigorMatch: rigorMatch model, state
    interestMatch: interestMatch model, state
    goalMatch: goalMatch model, state
    bankedTotal: state.banked / 30
    gatewayFront: gatewayFront profiles
    loadVariance: variance([p.credits for p in profiles]) / 4
    maxExamBearing: maxExamBearing / 4
    intensityVariance: variance([p.intensity for p in profiles]) / 16
    finalYearSlack: finalYearSlack model, state, profiles
    planLength: if model.terms.length > 0 then state.plan.length / model.terms.length else 0
  }

module.exports = { extract, variance }
