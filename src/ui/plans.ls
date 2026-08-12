# Plan rendering: the term grid, the graduation checklist, the engine's
# warnings and hints, and the difference between one plan and the top
# plan. Every number here comes from the engine; nothing is recomputed
# except the per-cell totals and the plan-to-plan diff. The grid is also
# where a plan is edited: a course dragged out is one the engine may not
# schedule, a course dragged in is pinned where it landed.

{ el, fill } = require './dom'
{ reqMatches } = require '../engine/gradreqs'
catalog = require './catalog'
state = require './state'
pairs = require './pairs'
whyUi = require './why'
drag = require './drag'

OBJECTIVE_LABEL =
  max_credits: 'Bank the most college credit'
  early_grad: 'Graduate high school early'

PHASE_LABEL =
  done: 'finished'
  now: 'in progress'

termKey = (entry) -> "#{entry.grade}:#{entry.term}"

# Which term each course sits in, for one plan.
placement = (plan) ->
  spots = {}
  for entry in plan.terms
    for id in entry.courses
      spots[id] = entry
  spots

# --- plan-to-plan difference ----------------------------------------------

listNames = (ids, name) ->
  shown = [name id for id in ids.slice 0, 2]
  rest = ids.length - shown.length
  text = shown.join ' and '
  if rest > 0 then "#{text} and #{rest} more" else text

diffText = (base, other, name) ->
  here = placement other
  there = placement base
  added = [id for id of here when not there[id]?].sort!
  dropped = [id for id of there when not here[id]?].sort!
  moved = [id for id of here when there[id]? and termKey(there[id]) isnt termKey(here[id])].sort!
  if added.length and dropped.length
    "swaps #{listNames dropped, name} for #{listNames added, name}"
  else if added.length
    "adds #{listNames added, name}"
  else if dropped.length
    "drops #{listNames dropped, name}"
  else if moved.length
    first = moved[0]
    rest = moved.length - 1
    tail = if rest > 0 then ", and moves #{rest} more" else ''
    "moves #{name first} from grade #{there[first].grade} #{there[first].term} " +
      "to grade #{here[first].grade} #{here[first].term}#{tail}"
  else
    'the same courses in the same terms; the plans differ only in scoring'

# --- component -------------------------------------------------------------

create = (ctx) ->
  root = el 'div', { class: 'results' }
  chips = ctx.chips
  selected = 0
  latest = null
  advice = []
  stale = false

  name = (id) ->
    course = ctx.catalog.byId[id]
    if course? then "#{id} #{course.name}" else id

  plan = -> latest?.plans?[selected] or null

  # Why the engine put a course in the plan on screen, for the chips
  # here and for the course dialog.
  whyFor = (id) -> plan!?.why?[id] or null

  # The whole grid on screen, past terms included: what a re-solve is
  # told to hold, and what an export flattens.
  terms = ->
    shown = plan!
    return [] unless shown?
    (latest.past or []) ++ shown.terms

  courseChip = (id) -> chips.chip id

  warningItem = (warning) -> el 'li', { text: warning }

  phaseText = (phase) ->
    switch phase
    | 'loading' => 'Loading the specsheet and the registries.'
    | 'embeddings' => 'Loading the course vectors for your goal.'
    | 'encoding' => 'Sending your goal to the encoding service.'
    | 'building' => 'Building the prerequisite graph.'
    | 'searching' => 'Searching term by term. This takes a few seconds.'
    | 'scoring' => 'Ranking the plans that survived.'
    | otherwise => 'Working.'

  # --- states ------------------------------------------------------------

  idle = !->
    latest := null
    advice := []
    fill root, [
      el 'div', { class: 'card empty' }, [
        el 'h2', { text: 'No plan yet' }
        el 'p', { text: 'Say where you stand on the left, then run the planner. Every plan it returns satisfies every prerequisite, offering, grade window, and load cap in the specsheet.' }
      ]
    ]

  running = (phase) !->
    fill root, [
      el 'div', { class: 'card running' }, [
        el 'h2', { text: 'Planning' }
        el 'div', { class: 'bar-indeterminate' }
        el 'p', { class: 'muted', text: phaseText phase }
        el 'button', { class: 'ghost', text: 'Cancel', onclick: !-> ctx.onCancel! }
      ]
    ]

  failed = (message) !->
    fill root, [
      el 'div', { class: 'card error' }, [
        el 'h2', { text: 'The planner stopped' }
        el 'p', { text: message }
      ]
    ]

  show = (result) !->
    latest := result
    advice := []
    selected := 0
    stale := false
    render!

  # Hints arrive after the plans, because the engine probes nearby
  # profiles to measure them.
  setHints = (list) !->
    advice := list or []
    render! if latest?

  markStale = !->
    return unless latest?
    return if stale
    stale := true
    render!

  # --- plan edits --------------------------------------------------------

  # Dragging a course out, or pressing its x, tells the engine never to
  # schedule it. Both halves of an A/B pair go together: half a course
  # is not a thing a student can take.
  reject = (id) !->
    state.avoidCourses pairs.unit ctx.pairs, id
    ctx.rerun!

  # Where a course dropped into a term cell belongs: the half that was
  # dropped lands where it was dropped, its partner in the term the
  # catalog offers it in, same grade.
  slotFor = (id, dropped, grade, term) ->
    return { grade: grade, term: term } if id is dropped
    course = ctx.catalog.byId[id]
    columns = catalog.termIds ctx.school
    for candidate in (course?.offered_terms or []) when candidate in columns and candidate isnt term
      return { grade: grade, term: candidate }
    { grade: grade, term: term }

  place = (id, grade, term) !->
    unit = pairs.unit ctx.pairs, id
    state.allowCourses unit
    for other in unit
      slot = slotFor other, id, grade, term
      state.setPin slot.grade, slot.term, other
    ctx.rerun!

  rebuild = !->
    shown = plan!
    return unless shown?
    state.pinPlan shown.terms
    ctx.rerun!

  # --- rendering ---------------------------------------------------------

  render = !->
    return idle! unless latest?
    result = latest
    unless result.plans.length
      return fill root, [
        el 'div', { class: 'card error' }, [
          el 'h2', { text: 'No plan fits' }
          el 'p', { text: 'The engine found no assignment that satisfies every rule. Loosen a pin, opt into a summer term, or raise your per-term limit.' }
        ]
      ]
    parts = []
    parts.push summaryCard result
    parts.push warningCard result.warnings if result.warnings.length
    parts.push hintCard advice if advice.length
    parts.push noticeCard result.notice if result.notice
    parts.push staleCard! if stale
    parts.push goalLine result if result.goalSource?
    parts.push tabs result
    parts.push planCard result, plan!
    fill root, parts

  staleCard = ->
    el 'div', { class: 'card note', text: 'Your profile changed since this plan was built. Run the planner again to apply it.' }

  noticeCard = (notice) ->
    el 'div', { class: 'card note', text: notice }

  # Said plainly, because a goal changes what the plans look like: it is a
  # ranking preference the student cannot see in the grid itself.
  goalLine = (result) ->
    how = if result.goalSource is 'precomputed'
      then 'matched to a goal precompiled for this school'
      else 'read by the encoding service'
    el 'p', { class: 'steer' }, [
      el 'span', { class: 'muted small', text: 'Plans steered toward' }
      el 'strong', { text: result.goal }
      el 'span', { class: 'muted small', text: "(#{how})" }
    ]

  warningCard = (warnings) ->
    el 'div', { class: 'card warn' }, [
      el 'h2', { text: 'Check these with a counselor' }
      el 'ul', {}, [warningItem warning for warning in warnings]
    ]

  hintItem = (text) ->
    el 'li', {}, [el('span', { class: 'hint-tag', text: 'hint' }), " #{text}"]

  # Advice, not a problem: each line is a change the student could make
  # and what the engine measured it would be worth.
  hintCard = (list) ->
    el 'div', { class: 'card hints' }, [
      el 'h2', { text: 'Worth considering' }
      el 'ul', {}, [hintItem text for text in list]
    ]

  summaryLine = (label, value) ->
    el 'div', { class: 'summary-line' }, [
      el 'span', { class: 'muted small', text: label }
      el 'strong', { text: value }
    ]

  summaryCard = (result) ->
    el 'div', { class: 'card summary' }, [
      summaryLine 'Objective', (OBJECTIVE_LABEL[result.objective] or result.objective)
      summaryLine 'Complete plans found', String result.planCount
      summaryLine 'Search time', "#{(result.elapsedMs / 1000).toFixed 1} s"
    ]

  tabButton = (result, i) ->
    el 'button', {
      class: if i is selected then 'tab active' else 'tab'
      text: "Plan #{i + 1}"
      onclick: !->
        selected := i
        render!
    }

  tabs = (result) ->
    buttons = []
    for shown, i in result.plans
      buttons.push tabButton result, i
    el 'div', { class: 'tabs' }, buttons

  stat = (label, value, note) ->
    el 'div', { class: 'stat' }, [
      el 'div', { class: 'stat-value', text: value }
      el 'div', { class: 'stat-label', text: label }
      (if note then el 'div', { class: 'stat-note', text: note } else null)
    ]

  bankedNote = ->
    el 'p', { class: 'muted small' }, [
      'The banked-credit number is an estimate from '
      el 'a', { href: 'data/registry/exams.yaml', target: '_blank', rel: 'noopener', text: 'registry/exams.yaml' }
      '. A college transfer table is the authority; confirm before you rely on it.'
    ]

  planCard = (result, shown) ->
    past = result.bankedPast or 0
    parts = []
    parts.push el 'div', { class: 'stats' }, [
      stat 'Banked college credit', String(shown.banked + past),
        (if past > 0 then 'estimate, terms behind you included' else 'estimate')
      stat 'Graduation credits missing', String(shown.gradRemaining), null
      stat 'Terms planned', String(shown.terms.length), null
      stat 'Plan score', shown.soft.toFixed(2), 'soft ranking'
    ]
    parts.push bankedNote!
    if selected > 0
      parts.push el 'p', { class: 'diff', text: "Plan #{selected + 1} #{diffText result.plans[0], shown, name}." }
    parts.push el 'div', { class: 'plan-head' }, [
      el 'h2', { text: 'Term by term' }
      el 'button', {
        class: 'choice'
        text: 'Rebuild around this plan'
        title: 'Pin every course where it sits, so the next run keeps the rest of the plan still'
        onclick: rebuild
      }
    ]
    parts.push el 'p', { class: 'muted small', text: 'Drag a course to another term to pin it there, or out of the grid to keep it out of every plan. The x on a chip does the same without dragging.' }
    parts.push grid result, shown
    parts.push el 'h2', { text: 'Graduation requirements' }
    parts.push checklist result, shown
    el 'div', { class: 'card plan' }, parts

  # --- the term grid -----------------------------------------------------

  creditsIn = (ids) ->
    credits = 0
    for id in ids
      credits += (ctx.catalog.byId[id]?.credits or 0)
    credits

  cellTotal = (ids) ->
    el 'div', { class: 'cell-total', text: "#{catalog.creditsLabel creditsIn ids} credits, #{ids.length} courses" }

  # Course order inside a grade row: linked A/B halves first and in the
  # same order in both terms, so a pair lines up across the two columns
  # and its connector runs straight. A pair counts as linked only when
  # its halves sit in neighboring columns of the same grade, which is
  # the only arrangement a connector can honestly draw.
  rowStems = (grade, columns, byKey) ->
    at = {}
    for term, column in columns
      entry = byKey["#{grade}:#{term}"]
      continue unless entry?
      for id in entry.courses
        stem = ctx.pairs.stemOf[id]
        continue unless stem?
        half = ctx.pairs.halfOf[id]
        (at[stem] ?= {})[half] = column
    linked = []
    for stem, spots of at when spots.a? and spots.b?
      linked.push stem if spots.b - spots.a is 1
    linked.sort!

  ordered = (ids, stems) ->
    rank = (id) ->
      stem = ctx.pairs.stemOf[id]
      at = if stem? then stems.indexOf stem else -1
      if at >= 0 then at else stems.length
    sorted = ids.slice!
    sorted.sort (a, b) ->
      diff = rank(a) - rank(b)
      if diff isnt 0 then diff else (if a < b then -1 else 1)
    sorted

  planChip = (id, stems) ->
    stem = ctx.pairs.stemOf[id]
    linked = stem? and stem in stems
    partner = ctx.pairs.partnerOf[id]
    options = {
      why: whyUi.marker ctx, whyFor id
      onRemove: !-> reject id
      removeTitle: 'Keep this course out of every plan'
      drag: { kind: 'plan', id: id }
    }
    if linked
      options.half = ctx.pairs.halfOf[id]
      options.title = "One course across two terms with #{partner}; they move together"
    chips.chip id, options

  emptyCell = (grade, term) ->
    el 'div', { class: 'grid-cell empty' }, [
      el 'div', { class: 'cell-label', text: "Grade #{grade} #{term}" }
      el 'p', { class: 'muted small', text: 'not in this plan' }
    ]

  # A term the marker says is behind the student: shown, greyed, and not
  # open to editing, because it has already happened.
  pastCell = (entry) ->
    el 'div', { class: "grid-cell past #{entry.phase}" }, [
      el 'div', { class: 'cell-label', text: "Grade #{entry.grade} #{entry.term}" }
      el 'div', { class: 'cell-phase', text: PHASE_LABEL[entry.phase] or entry.phase }
      el 'div', { class: 'chips' }, [courseChip id for id in entry.courses]
      cellTotal entry.courses
    ]

  cell = (grade, term, entry, stems) ->
    node = if entry? and entry.courses.length
      el 'div', { class: 'grid-cell' }, [
        el 'div', { class: 'cell-label', text: "Grade #{grade} #{term}" }
        el 'div', { class: 'chips' }, [planChip id, stems for id in ordered entry.courses, stems]
        cellTotal entry.courses
      ]
    else
      emptyCell grade, term
    node.addEventListener 'dragover', (event) !->
      return unless drag.held!?
      event.preventDefault!
      node.classList.add 'drop-over'
    node.addEventListener 'dragleave', !-> node.classList.remove 'drop-over'
    node.addEventListener 'drop', (event) !->
      held = drag.held!
      return unless held?
      event.preventDefault!
      node.classList.remove 'drop-over'
      drag.end!
      place held.id, grade, term
    node

  gradeRow = (grade, columns, byKey, pastByKey) ->
    stems = rowStems grade, columns, byKey
    cells = [el 'div', { class: 'grid-grade', text: "Grade #{grade}" }]
    for term in columns
      behind = pastByKey["#{grade}:#{term}"]
      cells.push (if behind? then pastCell behind else cell grade, term, byKey["#{grade}:#{term}"], stems)
    el 'div', { class: 'grid-row' }, cells

  # Where a course goes when it is dragged off the grid.
  dropAway = ->
    zone = el 'div', {
      class: 'dropzone'
      text: 'Drop a course here to keep it out of every plan'
    }
    zone.addEventListener 'dragover', (event) !->
      held = drag.held!
      return unless held? and held.kind is 'plan'
      event.preventDefault!
      zone.classList.add 'drop-over'
    zone.addEventListener 'dragleave', !-> zone.classList.remove 'drop-over'
    zone.addEventListener 'drop', (event) !->
      held = drag.held!
      return unless held?
      event.preventDefault!
      zone.classList.remove 'drop-over'
      drag.end!
      reject held.id
    zone

  grid = (result, shown) ->
    byKey = {}
    for entry in shown.terms
      byKey[termKey entry] = entry
    pastByKey = {}
    for entry in (result.past or [])
      pastByKey[termKey entry] = entry
    columns = catalog.termIds ctx.school
    head = [el 'div', { class: 'grid-corner' }]
    for term in columns
      head.push el 'div', { class: 'grid-term', text: term }
    rows = [el 'div', { class: 'grid-head' }, head]
    for grade in (ctx.school.grade_levels or [])
      rows.push gradeRow grade, columns, byKey, pastByKey
    el 'div', {}, [
      el 'div', { class: 'grid', style: "--terms: #{columns.length}" }, rows
      dropAway!
    ]

  # --- graduation requirements -------------------------------------------

  # Courses satisfying a requirement's predicate (tag, course list, or
  # content group), split into what the plan schedules and what the
  # student already holds.
  coursesMatching = (result, shown, req) ->
    planned = []
    for entry in shown.terms
      for id in entry.courses
        course = ctx.catalog.byId[id]
        planned.push id if course? and reqMatches req, course
    history = []
    profile = ctx.profile!
    pool = profile.completed ++ profile.inProgress
    pool = pool ++ profile.preHsCompleted if ctx.school.pre_hs_credit?.counts_toward_grad
    for entry in (result.past or [])
      pool = pool ++ entry.courses
    for id in pool
      course = ctx.catalog.byId[id]
      history.push id if course? and (reqMatches req, course) and id not in history
    { planned: planned, history: history }

  # One row per requirement: the label, how far along it is, and the
  # numbers. Everything behind it (what covers it, the school's note,
  # the line in the specsheet) opens on demand.
  requirementRow = (result, shown, req) ->
    earned = shown.coverage[req.id] or 0
    counted = Math.min earned, req.credits
    ratio = if req.credits > 0 then counted / req.credits else 1
    covering = coursesMatching result, shown, req
    detail = [el 'p', { class: 'muted small', text: 'Courses that cover it' }]
    detail.push el 'div', { class: 'chips' }, [courseChip id for id in covering.planned]
    if covering.history.length
      detail.push el 'p', { class: 'muted small', text: 'Already on your record' }
      detail.push el 'div', { class: 'chips' }, [courseChip id for id in covering.history]
    detail.push el 'p', { class: 'muted small', text: req.notes } if req.notes
    detail.push el 'p', { class: 'muted small' }, [
      "Requirement #{req.id} in "
      el 'a', { href: ctx.sourcePath, target: '_blank', rel: 'noopener', text: ctx.sourcePath }
      '.'
    ]
    el 'details', { class: if counted >= req.credits then 'req met' else 'req short' }, [
      el 'summary', { class: 'req-row' }, [
        el 'span', { class: 'req-label', text: req.label }
        el 'span', { class: 'bar' }, [el 'span', { class: 'bar-fill', style: "width: #{Math.round ratio * 100}%" }]
        el 'span', { class: 'req-count', text: "#{catalog.creditsLabel counted} / #{catalog.creditsLabel req.credits}" }
      ]
      el 'div', { class: 'req-detail' }, detail
    ]

  checklist = (result, shown) ->
    requirements = ctx.school.grad_requirements or []
    unless requirements.length
      return el 'p', { class: 'muted', text: 'This specsheet states no graduation requirements.' }
    rows = []
    for req in requirements
      rows.push requirementRow result, shown, req
    el 'div', { class: 'checklist' }, rows

  idle!
  {
    el: root, idle: idle, running: running, show: show, failed: failed,
    markStale: markStale, hints: setHints, whyFor: whyFor, terms: terms
  }

module.exports = { create, diffText }
