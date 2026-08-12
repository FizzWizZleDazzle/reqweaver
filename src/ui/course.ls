# Course detail dialog: the catalog entry behind every course chip in the
# app. It shows what the specsheet says, links to the file it came from,
# and carries the actions that change the profile (standing, pin, waiver).

{ el, fill } = require './dom'
catalog = require './catalog'
state = require './state'
pairs = require './pairs'
whyUi = require './why'

LEVEL_ORDER = <[ regular honors advanced ap ib college ]>

# One dialog serves the whole app; opening it for another course refills it.
create = (ctx) ->
  body = el 'div', { class: 'sheet-body' }
  dialog = el 'dialog', { class: 'sheet' }, [
    el 'form', { method: 'dialog', class: 'sheet-close-row' }, [
      el 'button', { class: 'ghost', text: 'Close', value: 'close' }
    ]
    body
  ]

  open = (id) !->
    fill body, view id
    dialog.showModal!
    body.scrollTop = 0

  # A course id anywhere in the dialog reopens the dialog on that course.
  link = (id) ->
    course = ctx.catalog.byId[id]
    label = if course? then "#{id} #{course.name}" else "#{id} (not in this catalog)"
    el 'button', { class: 'course-link', text: label, onclick: !-> open id }

  requirementView = (node) ->
    return link node if typeof node is 'string'
    children = []
    if node.all? and node.all.length
      children.push el 'div', { class: 'req-group' }, [
        el 'span', { class: 'req-op', text: 'all of' }
        el 'div', { class: 'req-items' }, [requirementView child for child in node.all]
      ]
    if node.any? and node.any.length
      children.push el 'div', { class: 'req-group' }, [
        el 'span', { class: 'req-op', text: 'any one of' }
        el 'div', { class: 'req-items' }, [requirementView child for child in node.any]
      ]
    el 'div', { class: 'req-node' }, children

  metaRow = (label, value) ->
    return null unless value?
    return null if typeof value is 'string' and value.length is 0
    el 'div', { class: 'meta-row' }, [
      el 'span', { class: 'meta-label', text: label }
      el 'span', { class: 'meta-value' }, value
    ]

  standingControls = (id) ->
    current = state.standingOf id
    choice = (field, label) ->
      active = current is field
      el 'button', {
        class: if active then 'choice active' else 'choice'
        text: label
        onclick: !->
          state.setStanding id, (if active then null else field)
          open id
      }
    el 'div', { class: 'choices' }, [
      choice 'completed', 'Completed'
      choice 'preHsCompleted', 'Completed before grade 9'
      choice 'inProgress', 'In progress now'
    ]

  pinControls = (id) ->
    pinned = state.pinnedTerm id
    if pinned?
      return el 'div', { class: 'choices' }, [
        el 'span', { class: 'pill', text: "pinned to grade #{pinned.grade} #{pinned.term}" }
        el 'button', {
          class: 'ghost'
          text: 'Unpin'
          onclick: !->
            state.removePin pinned.grade, pinned.term, id
            open id
        }
      ]
    options = [el 'option', { value: '', text: 'Pin to a term...' }]
    for slot in catalog.termSlots ctx.school
      options.push el 'option', { value: slot.key, text: slot.label }
    select = el 'select', { class: 'select' }, options
    select.addEventListener 'change', !->
      return unless select.value
      parts = select.value.split ':'
      state.addPin (Number parts[0]), parts[1], id
      open id
    select

  waiverControl = (id) ->
    waived = state.has 'waivers', id
    el 'button', {
      class: if waived then 'choice active' else 'choice'
      text: if waived then 'Prerequisites waived' else 'Waive prerequisites'
      onclick: !->
        state.toggle 'waivers', id
        open id
    }

  # The click-only path to what dragging a chip off the grid does. Both
  # halves of an A/B pair go together.
  avoidControl = (id) ->
    unit = pairs.unit ctx.pairs, id
    excluded = state.has 'avoid', id
    el 'button', {
      class: if excluded then 'choice active' else 'choice'
      text: if excluded then 'Kept out of plans' else 'Never plan this'
      title: if unit.length > 1
        then "Applies to both halves: #{unit.join ' and '}"
        else 'The engine plans around this course; a pin still overrides it'
      onclick: !->
        if excluded then state.allowCourses unit else state.avoidCourses unit
        ctx.rerun?!
        open id
    }

  # The click-only path to what dragging a course into the grid does:
  # place it (and its A/B partner) in a term, or take it off.
  gridControls = (id) ->
    placed = ctx.placedIn? id
    if placed?
      return el 'div', { class: 'choices' }, [
        el 'span', { class: 'pill', text: "on your grid in grade #{placed.grade} #{placed.term}" }
        el 'button', {
          class: 'ghost'
          text: 'Take off the grid'
          onclick: !->
            ctx.removeFromGrid? id
            open id
        }
      ]
    options = [el 'option', { value: '', text: 'Place in a term...' }]
    for slot in catalog.termSlots ctx.school
      options.push el 'option', { value: slot.key, text: slot.label }
    select = el 'select', { class: 'select' }, options
    select.addEventListener 'change', !->
      return unless select.value
      parts = select.value.split ':'
      ctx.place? id, (Number parts[0]), parts[1]
      open id
    select

  # What the engine says this course earned its slot for, in the plan on
  # screen. Absent for a course no plan schedules.
  reasonList = (id) ->
    lines = whyUi.sentences ctx, (ctx.whyFor? id)
    return null unless lines.length
    el 'div', {}, [
      el 'h3', { text: 'Why it is in the plan' }
      el 'ul', { class: 'why-list' }, [el 'li', { text: line } for line in lines]
    ]

  pairLine = (id) ->
    partner = ctx.pairs?.partnerOf?[id]
    return null unless partner?
    other = ctx.catalog.byId[partner]
    el 'p', { class: 'muted small', text: "One course across two terms with #{partner} #{other?.name or ''}. The planner never schedules one half without the other." }

  view = (id) ->
    course = ctx.catalog.byId[id]
    unless course?
      return [el 'p', { class: 'muted', text: "#{id} is not in this catalog." }]
    level = catalog.levelOf course
    note = catalog.levelNote ctx.levels, course
    dependents = ctx.catalog.dependents[id] or []
    parts = []
    parts.push el 'header', { class: 'sheet-head' }, [
      el 'div', { class: 'sheet-id', text: course.id }
      el 'h2', { text: course.name }
      el 'div', { class: 'badges' }, [
        el 'span', { class: "badge level-#{level}", text: level }
        el 'span', { class: 'badge', text: "#{catalog.creditsLabel course.credits} credits" }
        (if course.periods and course.periods > 1
          then el 'span', { class: 'badge', text: "#{course.periods} periods" }
          else null)
      ]
    ]
    if note.length
      parts.push el 'p', { class: 'muted small', text: "This level #{note} (registry/levels.yaml)." }
    if course.description
      parts.push el 'p', { class: 'description', text: course.description }
    parts.push pairLine id
    parts.push reasonList id

    offered = (course.offered_terms or []).join ', '
    offered = 'no term stated; only an open term can hold it' unless offered.length
    meta = []
    meta.push metaRow 'Tags', (course.tags or []).join ', '
    meta.push metaRow 'Offered', offered
    meta.push metaRow 'Grades', (course.grade_levels or []).join ', '
    meta.push metaRow 'Exam', course.exam
    meta.push metaRow 'Content group', course.content
    if (course.excludes or []).length
      meta.push metaRow 'Never with', el('span', {}, [link other for other in course.excludes])
    if (course.coreqs or []).length
      meta.push metaRow 'Corequisites', el('span', {}, [link other for other in course.coreqs])
    if course.note
      meta.push metaRow 'Catalog note', course.note
    parts.push el 'div', { class: 'meta' }, meta

    parts.push el 'h3', { text: 'Prerequisites' }
    if catalog.hasPrereqs course
      parts.push requirementView catalog.requirementTree course
      if state.has 'waivers', course.id
        parts.push el 'p', { class: 'muted small', text: 'Waived in your profile: the planner treats these as met.' }
    else
      parts.push el 'p', { class: 'muted', text: 'None.' }

    parts.push el 'h3', { text: 'Unlocks' }
    if dependents.length
      parts.push el 'div', { class: 'link-list' }, [link other for other in dependents.slice 0, 24]
      if dependents.length > 24
        parts.push el 'p', { class: 'muted small', text: "and #{dependents.length - 24} more" }
    else
      parts.push el 'p', { class: 'muted', text: 'No course in this catalog requires it.' }

    parts.push el 'h3', { text: 'Your plan' }
    parts.push gridControls id

    parts.push el 'h3', { text: 'Your profile' }
    parts.push standingControls id
    parts.push el 'div', { class: 'choices' }, [waiverControl id, avoidControl id]
    parts.push pinControls id

    parts.push el 'p', { class: 'provenance' }, [
      'Source: '
      el 'a', { href: ctx.sourcePath, target: '_blank', rel: 'noopener', text: ctx.sourcePath }
      ", course #{course.id}, catalog year #{ctx.school.catalog_year}."
    ]
    parts

  { el: dialog, open: open }

module.exports = { create, LEVEL_ORDER }
