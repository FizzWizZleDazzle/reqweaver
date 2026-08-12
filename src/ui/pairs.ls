# A/B halves. A catalog often splits a year-long course into two ids
# whose names differ only in the trailing letter, where the second half
# names the first as a direct prerequisite. Those two are one course a
# student cannot take half of, so the app shows them linked and moves
# them together. Which courses pair is read from the catalog; no id or
# name is ever hard-coded here.

# The last whitespace-separated word of a name, when it is a single
# letter: "Algebra 1 A" -> { stem: 'Algebra 1', letter: 'A' }.
trailingLetter = (text) ->
  parts = String(text or '').trim!.split /\s+/
  last = parts[parts.length - 1] or ''
  return null unless last.length is 1
  { stem: parts.slice(0, -1).join(' '), letter: last }

directPrereqs = (course) -> ((course.prereqs or {}).all_of or [])

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
    continue unless first.id in directPrereqs second
    a = trailingLetter first.name
    b = trailingLetter second.name
    continue unless a? and b? and a.stem is b.stem and a.letter isnt b.letter
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

module.exports = { index, unit, trailingLetter }
