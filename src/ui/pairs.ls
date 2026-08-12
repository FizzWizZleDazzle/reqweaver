# A/B halves. A catalog splits a year-long course into two ids that
# differ only in a trailing A/B letter, where the B half's only direct
# prerequisite is the A half. Those two are one course a student cannot
# take half of, so the app shows them linked and moves them together.
# The rule matches the engine's derivePairs and reads ids, not names:
# names carry suffixes ("AP Biology A Double Period") that broke a
# name-based rule, and unrelated courses can share a name stem.

# partnerOf: id -> the other half. halfOf: id -> 'a' or 'b'. stemOf:
# id -> the first half's id, which orders a pair inside a term.
index = (school) ->
  byId = {}
  for course in (school.courses or [])
    byId[course.id] = course
  partnerOf = {}
  halfOf = {}
  stemOf = {}
  for id, second of byId when id.slice(-1) is 'B' and id.length > 1
    first = byId[id.slice(0, -1) + 'A']
    continue unless first?
    # the A half appears among B's prerequisites; B usually also
    # carries the course's own entry prerequisites, so demanding A be
    # the only one broke most real pairs
    p = second.prereqs or {}
    continue unless first.id in (p.all_of or [])
    partnerOf[first.id] = second.id
    partnerOf[second.id] = first.id
    halfOf[first.id] = 'a'
    halfOf[second.id] = 'b'
    stemOf[first.id] = first.id
    stemOf[second.id] = first.id
  { partnerOf: partnerOf, halfOf: halfOf, stemOf: stemOf }

# Both halves of whatever a course belongs to, the course itself when it
# has no partner. Everything that acts on a pair goes through this.
unit = (pairs, id) ->
  partner = pairs.partnerOf[id]
  if partner? then [id, partner] else [id]

module.exports = { index, unit }
