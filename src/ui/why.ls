# Why a course is in the plan, in words. The engine returns reasons as
# { kind, detail } pairs and a necessity score; this turns them into the
# one-word marker a chip carries and the sentences the course dialog
# spells out. Nothing is decided here: the wording follows the engine.

SWAPPABLE = 0.2

# Most binding reason first: what a chip shows when a course has more
# than one.
ORDER = <[ requirement prerequisite banked goal interest none ]>

LABEL =
  requirement: 'requirement'
  prerequisite: 'prereq'
  banked: 'banks credit'
  goal: 'goal'
  interest: 'interest'
  swappable: 'swappable'

# The marker kind: swappable when the engine scored the course as
# filler, otherwise its strongest reason.
kindOf = (entry) ->
  return 'swappable' unless entry?
  return 'swappable' if entry.necessity < SWAPPABLE
  found = 'swappable'
  for kind in ORDER
    for reason in (entry.reasons or []) when reason.kind is kind
      return if kind is 'none' then 'swappable' else kind
  found

amount = (value) ->
  n = Number(value or 0)
  if n is Math.round n then String n else n.toFixed 1

nameOf = (ctx, id) ->
  course = ctx.catalog.byId[id]
  if course? then course.name else id

requirementLabel = (ctx, id) ->
  for req in (ctx.school.grad_requirements or []) when req.id is id
    return req.label or req.id
  id

# "AP Physics C Mechanics A and two more"
namesOf = (ctx, ids) ->
  unique = []
  for id in (ids or [])
    unique.push id unless id in unique
  shown = [nameOf ctx, id for id in unique.slice 0, 2]
  rest = unique.length - shown.length
  text = shown.join ' and '
  if rest > 0 then "#{text} and #{rest} more" else text

sentence = (ctx, reason) ->
  switch reason.kind
  | 'requirement' => "covers the #{requirementLabel ctx, reason.detail} requirement"
  | 'prerequisite' => "prerequisite for #{namesOf ctx, reason.detail}"
  | 'banked' => "banks about #{amount reason.detail} college credits, by the exam registry's estimate"
  | 'goal' => 'its catalog description is close to the goal you stated'
  | 'interest' => 'it carries a tag you picked as an interest'
  | otherwise => 'nothing else in the plan needs it, so it is yours to swap for anything you would rather do'

sentences = (ctx, entry) ->
  return [] unless entry?
  [sentence ctx, reason for reason in (entry.reasons or [])]

# One line for a chip's tooltip.
tooltip = (ctx, entry) ->
  lines = sentences ctx, entry
  return 'swappable' unless lines.length
  lines.join '; '

label = (kind) -> LABEL[kind] or kind

# What a chip needs to draw its marker.
marker = (ctx, entry) ->
  return null unless entry?
  kind = kindOf entry
  { kind: kind, label: label(kind), title: tooltip ctx, entry }

module.exports = { kindOf, label, marker, sentences, tooltip, ORDER, SWAPPABLE }
