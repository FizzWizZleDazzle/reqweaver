# The read-only view behind a /s/<code> link. It fetches the saved plan
# by its id and renders what the plan says: the term grid, how far it
# gets toward graduation, the banked-credit estimate, and the specsheet
# it was built against. Nothing here edits anything, and there is no
# profile editor: a shared plan belongs to whoever made it.

{ el, fill } = require './dom'
{ reqMatches } = require '../engine/gradreqs'
catalog = require './catalog'
api = require './api'

termKey = (entry) -> "#{entry.grade}:#{entry.term}"

frame = (kids) ->
  el 'div', { class: 'shared' }, kids

header = ->
  el 'header', { class: 'topbar' }, [
    el 'div', { class: 'brand' }, [
      el 'span', { class: 'wordmark', text: 'reqweaver' }
      el 'span', { class: 'tagline', text: 'a shared plan, read only' }
    ]
    el 'div', { class: 'topbar-controls' }, [
      el 'a', { class: 'choice', href: '/', text: 'Plan your own' }
    ]
  ]

stamp = (value) ->
  return null unless value?
  try
    (new Date value).toISOString!.slice 0, 10
  catch e
    null

# --- rendering ------------------------------------------------------------

create = (deps) ->

  # A course the reader can see the name of, when the school this plan
  # was built against is still in the index; otherwise the id alone.
  chip = (courses, id) ->
    course = courses?[id]
    parts = [el 'span', { class: 'chip-id', text: id }]
    if course?
      parts.push el 'span', { class: 'chip-name', text: course.name }
      parts.push el 'span', { class: "badge level-#{catalog.levelOf course}", text: catalog.levelOf course }
    el 'span', { class: 'chip' }, [el 'span', { class: 'chip-main' }, parts]

  cell = (courses, grade, term, entry) ->
    unless entry? and entry.courses.length
      return el 'div', { class: 'grid-cell empty' }, [
        el 'div', { class: 'cell-label', text: "Grade #{grade} #{term}" }
        el 'p', { class: 'muted small', text: 'nothing in this term' }
      ]
    credits = 0
    for id in entry.courses
      credits += (courses?[id]?.credits or 0)
    el 'div', { class: 'grid-cell' }, [
      el 'div', { class: 'cell-label', text: "Grade #{grade} #{term}" }
      el 'div', { class: 'chips' }, [chip courses, id for id in entry.courses]
      el 'div', { class: 'cell-total', text: "#{catalog.creditsLabel credits} credits, #{entry.courses.length} courses" }
    ]

  # Without the school the plan still has its assignments, so the grid
  # is drawn from the grades and terms the assignments themselves name.
  gridShape = (school, assignments) ->
    if school?
      { grades: (school.grade_levels or []), columns: catalog.termIds school }
    else
      grades = []
      columns = []
      for entry in assignments
        grades.push entry.grade unless entry.grade in grades
        columns.push entry.term unless entry.term in columns
      { grades: grades.sort!, columns: columns }

  grid = (school, courses, assignments) ->
    byKey = {}
    for entry in assignments
      byKey[termKey entry] = entry
    shape = gridShape school, assignments
    head = [el 'div', { class: 'grid-corner' }]
    for term in shape.columns
      head.push el 'div', { class: 'grid-term', text: term }
    rows = [el 'div', { class: 'grid-head' }, head]
    for grade in shape.grades
      cells = [el 'div', { class: 'grid-grade', text: "Grade #{grade}" }]
      for term in shape.columns
        cells.push cell courses, grade, term, byKey["#{grade}:#{term}"]
      rows.push el 'div', { class: 'grid-row' }, cells
    el 'div', { class: 'grid', style: "--terms: #{shape.columns.length}" }, rows

  requirementRow = (school, courses, payload, req) ->
    earned = (payload.coverage or {})[req.id] or 0
    counted = Math.min earned, req.credits
    ratio = if req.credits > 0 then counted / req.credits else 1
    covering = []
    for entry in (payload.assignments or [])
      for id in entry.courses
        course = courses?[id]
        covering.push id if course? and reqMatches req, course
    detail = [el 'p', { class: 'muted small', text: 'Courses that cover it' }]
    detail.push el 'div', { class: 'chips' }, [chip courses, id for id in covering]
    detail.push el 'p', { class: 'muted small', text: req.notes } if req.notes
    el 'details', { class: if counted >= req.credits then 'req met' else 'req short' }, [
      el 'summary', { class: 'req-row' }, [
        el 'span', { class: 'req-label', text: req.label }
        el 'span', { class: 'bar' }, [el 'span', { class: 'bar-fill', style: "width: #{Math.round ratio * 100}%" }]
        el 'span', { class: 'req-count', text: "#{catalog.creditsLabel counted} / #{catalog.creditsLabel req.credits}" }
      ]
      el 'div', { class: 'req-detail' }, detail
    ]

  stat = (label, value, note) ->
    el 'div', { class: 'stat' }, [
      el 'div', { class: 'stat-value', text: value }
      el 'div', { class: 'stat-label', text: label }
      (if note then el 'div', { class: 'stat-note', text: note } else null)
    ]

  planView = (record, payload, school, courses, entry) ->
    pin = (payload.specsheetPins or [])[0] or {}
    parts = []
    parts.push el 'div', { class: 'card summary' }, [
      el 'div', { class: 'summary-line' }, [
        el 'span', { class: 'muted small', text: 'Plan' }
        el 'strong', { text: payload.name or 'a shared plan' }
      ]
      el 'div', { class: 'summary-line' }, [
        el 'span', { class: 'muted small', text: 'School' }
        el 'strong', { text: school?.name or pin.id or 'not stated' }
      ]
      el 'div', { class: 'summary-line' }, [
        el 'span', { class: 'muted small', text: 'Catalog year' }
        el 'strong', { text: String(school?.catalog_year or pin.catalogYear or 'not stated') }
      ]
      el 'div', { class: 'summary-line' }, [
        el 'span', { class: 'muted small', text: 'Shared' }
        el 'strong', { text: (stamp(record?.updatedAt) or stamp(payload.savedAt) or 'not stated') }
      ]
    ]
    body = []
    body.push el 'div', { class: 'stats' }, [
      stat 'Banked college credit', String(payload.banked or 0), 'estimate'
      stat 'Graduation credits missing', String(payload.gradRemaining or 0), null
      stat 'Terms planned', String((payload.assignments or []).length), null
    ]
    unless school?
      body.push el 'p', { class: 'muted small', text: "This plan was built against #{pin.id or 'a school'}, which this build does not carry, so courses show as catalog ids only." }
    body.push el 'h2', { text: 'Term by term' }
    body.push grid school, courses, (payload.assignments or [])
    if school? and (school.grad_requirements or []).length
      body.push el 'h2', { text: 'Graduation requirements' }
      body.push el 'div', { class: 'checklist' },
        [requirementRow school, courses, payload, req for req in school.grad_requirements]
    parts.push el 'div', { class: 'card plan' }, body
    parts.push el 'p', { class: 'muted small', text: 'This is someone else\'s plan, shown as it was saved. It is a proposal for a counselor, not a schedule.' }
    if entry?
      parts.push el 'p', { class: 'muted small' }, [
        'Course data comes from '
        el 'a', { href: entry.path, target: '_blank', rel: 'noopener', text: entry.path }
        '.'
      ]
    parts

  missing = (message) ->
    [
      el 'div', { class: 'card error' }, [
        el 'h2', { text: 'No plan at this link' }
        el 'p', { text: message }
        el 'p', {}, [el 'a', { href: '/', text: 'Plan your own' }]
      ]
    ]

  # code -> the page. Everything the reader needs comes from the API and
  # the school index; nothing is read from this browser's profile.
  open = (root, code, config, index) ->
    fill root, [header!, frame [el 'div', { class: 'card empty' }, [
      el 'h2', { text: 'Loading the shared plan' }
      el 'p', { class: 'muted', text: 'Fetching it from the reqweaver API.' }
    ]]]
    api.readPlan(config, code).then (result) ->
      unless result.ok and result.body?.payload?
        reason = if result.status is 404
          then 'That code does not name a saved plan. It may have been deleted, or the link may be mistyped.'
          else if result.status is 0
            then 'The reqweaver API is not reachable from here.'
            else "The API answered #{result.status}."
        return fill root, [header!, frame missing reason]
      record = result.body
      payload = record.payload
      pin = (payload.specsheetPins or [])[0] or {}
      entry = null
      for item in ((index?.schools) or []) when item.id is pin.id
        entry := item
      unless entry?
        return fill root, [header!, frame planView record, payload, null, null, null]
      deps.loadSchool(entry).then ((school) ->
        fill root, [header!, frame planView record, payload, school, (catalog.index school).byId, entry]
      ), (->
        fill root, [header!, frame planView record, payload, null, null, null])

  { open }

module.exports = { create }
