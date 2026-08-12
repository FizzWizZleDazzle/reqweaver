# Standing read off the plan on screen. A "you are here" marker (a grade
# and a term) splits the grid: terms before it are finished, the marker
# term is in progress, and only the terms after it are still open to
# planning. The worker uses this to fix the past before it searches, and
# the profile export flattens the same split into the completed and
# in-progress lists the command line planner reads.

termIds = (school) ->
  calendar = (school.terms_per_year or []).slice!
  calendar.sort (a, b) -> a.sequence - b.sequence
  [slot.id for slot in calendar]

# Every (grade, term) slot in calendar order, optional terms included.
slots = (school) ->
  out = []
  for grade in (school.grade_levels or [])
    for term in termIds school
      out.push { grade: grade, term: term, key: "#{grade}:#{term}" }
  out

orderIndex = (school) ->
  order = {}
  for slot, i in slots school
    order[slot.key] = i
  order

# Where the marker sits in that order; -1 when no marker is set or it
# names a slot this school does not have.
markerIndex = (school, marker) ->
  return -1 unless marker? and marker.grade? and marker.term?
  found = -1
  for slot, i in slots school
    found := i if slot.grade is Number(marker.grade) and slot.term is String(marker.term)
  found

# planTerms is the grid on screen ([{grade, term, courses}]). Terms
# before the marker count as completed and the marker term as in
# progress; the profile's own lists are additions, never replaced.
derive = (school, profile, planTerms, marker) ->
  order = orderIndex school
  cut = markerIndex school, marker
  completed = ((profile or {}).completed or []).slice!
  inProgress = ((profile or {}).inProgress or []).slice!
  past = []
  if cut >= 0
    for entry in (planTerms or [])
      i = order["#{entry.grade}:#{entry.term}"]
      continue unless i? and i <= cut
      phase = if i < cut then 'done' else 'now'
      past.push {
        grade: entry.grade
        term: entry.term
        courses: (entry.courses or []).slice!
        phase: phase
      }
      for id in (entry.courses or [])
        list = if phase is 'done' then completed else inProgress
        list.push id unless id in list
    past.sort (a, b) -> order["#{a.grade}:#{a.term}"] - order["#{b.grade}:#{b.term}"]
  inProgress = [id for id in inProgress when id not in completed]
  { completed: completed, inProgress: inProgress, past: past, cut: cut }

# The terms a search may still fill. Trimming the model's term list is
# what keeps a plan from putting a course into a term that has already
# happened; indexes are renumbered because the search reads term.index.
trimTerms = (school, terms, cut) ->
  return terms if cut < 0
  order = orderIndex school
  kept = [t for t in terms when (order["#{t.grade}:#{t.term}"] ? -1) > cut]
  for t, i in kept
    t.index = i
  kept

# Grades the student has not started yet, for probes that re-solve from
# scratch and would otherwise plan around terms that are already spent.
remainingGrades = (school, marker) ->
  cut = markerIndex school, marker
  return (school.grade_levels or []) if cut < 0
  grade = Number marker.grade
  [g for g in (school.grade_levels or []) when g > grade]

module.exports = {
  termIds, slots, orderIndex, markerIndex, derive, trimTerms, remainingGrades
}
