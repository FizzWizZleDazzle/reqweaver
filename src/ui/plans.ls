# The planner surface: the term grid the student builds by hand, the
# live rule check over it, and the graduation tracker. Every grid change
# persists to localStorage and goes to the worker's validate path; a
# placement that breaks a rule is marked, never blocked or undone, since
# the student may know an exception the catalog does not (the same
# stance as pin overrides). The solver is an assist on this surface:
# its proposals land in the same grid and stay editable.

{ el, fill } = require './dom'
{ reqMatches } = require '../engine/gradreqs'
catalog = require './catalog'
state = require './state'
pairs = require './pairs'
standing = require '../standing'
whyUi = require './why'
drag = require './drag'

# grid changes arrive in bursts (a drop, an opt-in, a save); one check
# covers them all
VALIDATE_DELAY = 120

PHASE_LABEL =
  done: 'finished'
  now: 'in progress'

termKey = (entry) -> "#{entry.grade}:#{entry.term}"

# --- proposal-to-proposal difference ---------------------------------------

placement = (plan) ->
  spots = {}
  for entry in plan.terms
    for id in entry.courses
      spots[id] = entry
  spots

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
  latest = null      # the last solve result, for markers and proposals
  selected = 0
  advice = []
  stale = false      # something changed since the last solve finished
  solving = null     # the phase while a solve runs, else null
  solveError = null
  report = null      # the last validate report for the grid on screen
  checkNote = null   # why the rule check itself is not answering
  applying = false   # a grid write of our own; not a reason to go stale
  timer = null

  name = (id) ->
    course = ctx.catalog.byId[id]
    if course? then "#{id} #{course.name}" else id

  # --- the grid, read and written through state ---------------------------

  grid = -> state.grid ctx.entry.id

  writeGrid = (entries) !->
    applying := true
    state.setGrid ctx.entry.id, entries
    applying := false

  # The grid's non-empty terms: what a solve is told to hold, what an
  # export flattens, and what a save stores.
  terms = ->
    [entry for entry in grid! when (entry.courses or []).length]

  placedIn = (id) ->
    found = null
    for entry in grid! when id in (entry.courses or [])
      found = entry
    found

  # Why the engine put a course where it is, in the last proposal. A
  # course placed by hand has no entry and no marker.
  whyFor = (id) -> latest?.plans?[selected]?.why?[id] or null

  # The grid as plain data for a save or a share, with the numbers the
  # rule check produced for it.
  snapshot = ->
    shown = terms!
    return null unless shown.length and report?
    {
      terms: shown
      coverage: {} <<< report.coverage
      banked: report.banked or 0
      gradRemaining: report.remaining
      objective: state.profile!.objective
    }

  # --- the rule check -----------------------------------------------------

  schedule = !->
    window.clearTimeout timer if timer?
    timer := window.setTimeout (!->
      timer := null
      ctx.validate? { plan: grid! }), VALIDATE_DELAY

  applyReport = (message) !->
    report := message
    checkNote := null
    render!

  checkFailed = (message) !->
    checkNote := String(message?.message or 'the rule check failed')
    render!

  # issues indexed for rendering: per chip, and per term for the
  # capacity issues that carry no course
  issueIndex = ->
    byChip = {}
    byTerm = {}
    for item in ((report?.issues) or [])
      key = "#{item.grade}:#{item.term}"
      if item.course?
        byChip[key] = {} unless byChip[key]?
        byChip[key][item.course] = [] unless byChip[key][item.course]?
        byChip[key][item.course].push item.detail
      else
        byTerm[key] = [] unless byTerm[key]?
        byTerm[key].push item.detail
    { byChip: byChip, byTerm: byTerm }

  # --- grid edits ---------------------------------------------------------

  # Dropping into an optional term (summer) opts that year's term in on
  # the profile; without the opt-in the term is not in the calendar the
  # rules are checked against.
  optIn = (grade, term) !->
    for slot in catalog.termSlots ctx.school
      if slot.grade is grade and slot.term is term and slot.optional
        state.add 'optionalTerms', slot.key

  without = (entries, ids) ->
    out = []
    for entry in entries
      kept = [c for c in (entry.courses or []) when c not in ids]
      out.push { grade: entry.grade, term: entry.term, courses: kept } if kept.length
    out

  addTo = (entries, grade, term, id) ->
    out = []
    found = false
    for entry in entries
      if entry.grade is grade and entry.term is term
        found := true
        out.push { grade: entry.grade, term: entry.term, courses: entry.courses ++ [id] }
      else
        out.push entry
    out.push { grade: grade, term: term, courses: [id] } unless found
    out

  # Where a course dropped into a term cell belongs: the half that was
  # dropped lands where it was dropped, its partner in a term the
  # catalog offers it in, on its own side of the pair and in the same
  # grade.
  slotFor = (id, dropped, grade, term) ->
    return { grade: grade, term: term } if id is dropped
    columns = catalog.termIds ctx.school
    here = columns.indexOf term
    after = ctx.pairs.halfOf[id] is 'b'
    offered = [t for t in ((ctx.catalog.byId[id]?.offered_terms) or []) when t in columns and t isnt term]
    for candidate in offered
      at = columns.indexOf candidate
      return { grade: grade, term: candidate } if (at > here) is after
    return { grade: grade, term: offered[0] } if offered.length
    { grade: grade, term: term }

  # A drop places the course (and its A/B partner) in the grid; it does
  # not pin, and it never re-solves. A course dragged in is wanted, so
  # it stops being avoided.
  place = (id, grade, term) !->
    unit = pairs.unit ctx.pairs, id
    avoided = [c for c in unit when state.has 'avoid', c]
    state.allowCourses avoided if avoided.length
    entries = without grid!, unit
    for other in unit
      slot = slotFor other, id, grade, term
      optIn slot.grade, slot.term
      entries = addTo entries, slot.grade, slot.term, other
    writeGrid entries

  removeFrom = (id) !->
    unit = pairs.unit ctx.pairs, id
    writeGrid without(grid!, unit)

  # --- the solver as an assist --------------------------------------------

  autoplan = !->
    solveError := null
    ctx.rerun!

  # Pin every placed course in a term still open to planning where it
  # sits, then re-solve: the hand-built grid is kept and the search
  # fills around it.
  rebuild = !->
    shown = terms!
    return unless shown.length
    order = standing.orderIndex ctx.school
    cut = standing.markerIndex ctx.school, state.now!
    open = [entry for entry in shown when (order[termKey entry] ? 1e9) > cut]
    state.pinPlan open
    autoplan!

  # A proposal lands in the grid, past terms included, and stays
  # editable there.
  loadPlan = (i) !->
    shown = latest?.plans?[i]
    return unless shown?
    selected := i
    stale := false
    entries = []
    for entry in ((latest.past or []) ++ shown.terms)
      entries.push { grade: entry.grade, term: entry.term, courses: (entry.courses or []).slice! }
    writeGrid entries
    render!

  show = (result) !->
    latest := result
    advice := []
    solving := null
    solveError := null
    stale := false
    if result.plans.length then loadPlan 0 else render!

  running = (phase) !->
    solving := phase
    solveError := null
    render!

  failed = (message) !->
    solving := null
    solveError := message
    render!

  stopped = !->
    solving := null
    render!

  setHints = (list) !->
    advice := list or []
    render!

  # Any state change re-renders and re-checks the grid; a change we did
  # not make ourselves also dates the last solve.
  refresh = !->
    stale := true if latest? and not applying
    render!
    schedule!

  phaseText = (phase) ->
    switch phase
    | 'loading' => 'Loading the specsheet and the registries.'
    | 'embeddings' => 'Loading the course vectors for your goal.'
    | 'encoding' => 'Sending your goal to the encoding service.'
    | 'building' => 'Building the prerequisite graph.'
    | 'searching' => 'Searching term by term. This takes a few seconds.'
    | 'scoring' => 'Ranking the plans that survived.'
    | otherwise => 'Working.'

  # --- rendering ----------------------------------------------------------

  render = !->
    parts = []
    parts.push solveCard!
    parts.push warningCard latest.warnings if latest? and (latest.warnings or []).length
    parts.push hintCard advice if advice.length
    parts.push noticeCard latest.notice if latest?.notice
    parts.push goalLine latest if latest?.goalSource?
    parts.push gridCard!
    fill root, parts

  noticeCard = (notice) ->
    el 'div', { class: 'card note', text: notice }

  goalLine = (result) ->
    how = if result.goalSource is 'precomputed'
      then 'matched to a goal precompiled for this school'
      else 'read by the encoding service'
    el 'p', { class: 'steer' }, [
      el 'span', { class: 'muted small', text: 'Proposals steered toward' }
      el 'strong', { text: result.goal }
      el 'span', { class: 'muted small', text: "(#{how})" }
    ]

  warningCard = (warnings) ->
    el 'div', { class: 'card warn' }, [
      el 'h2', { text: 'Check these with a counselor' }
      el 'ul', {}, [el 'li', { text: warning } for warning in warnings]
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

  proposalButton = (i) ->
    el 'button', {
      class: if (i is selected and not stale) then 'tab active' else 'tab'
      text: "Proposal #{i + 1}"
      title: 'Load this proposal into the grid'
      onclick: !-> loadPlan i
    }

  # The solver card: the auto-plan actions, the run in progress, and
  # the proposals of the last run, each loadable into the grid.
  solveCard = ->
    body = []
    body.push el 'div', { class: 'plan-head' }, [
      el 'h2', { text: 'Auto-plan' }
      el 'div', { class: 'choices' }, [
        el 'button', {
          class: 'primary'
          text: 'Auto-plan'
          title: 'Search for complete plans and load the best into the grid'
          disabled: (if solving? then true else null)
          onclick: autoplan
        }
        el 'button', {
          class: 'choice'
          text: 'Fill around this grid'
          title: 'Pin every placed course where it sits, then plan the rest'
          disabled: (if (solving? or not terms!.length) then true else null)
          onclick: rebuild
        }
      ]
    ]
    body.push el 'p', { class: 'muted small', text: 'The result lands in the grid below and stays editable. Every proposal satisfies every prerequisite, offering, grade window, and load cap in the specsheet.' }
    if solving?
      body.push el 'div', { class: 'bar-indeterminate' }
      body.push el 'p', { class: 'muted small', text: phaseText solving }
      body.push el 'button', { class: 'ghost', text: 'Cancel', onclick: !-> ctx.onCancel! }
    if solveError?
      body.push el 'p', { class: 'check-line issues', text: "The planner stopped: #{solveError}" }
    if latest? and not solving?
      if latest.plans.length
        buttons = []
        for shown, i in latest.plans
          buttons.push proposalButton i
        body.push el 'div', { class: 'tabs' }, buttons
        if selected > 0 and not stale
          body.push el 'p', { class: 'diff', text: "Proposal #{selected + 1} #{diffText latest.plans[0], latest.plans[selected], name}." }
        body.push el 'p', { class: 'muted small', text: "#{latest.planCount} complete plans found in #{(latest.elapsedMs / 1000).toFixed 1} s." }
        if stale
          body.push el 'p', { class: 'muted small', text: 'The grid or profile changed since this run; the proposals may no longer match it.' }
      else
        body.push el 'p', { class: 'check-line issues', text: 'No complete plan fits. Loosen a pin, opt into a summer term, or raise your per-term limit; the grid itself is untouched.' }
    el 'div', { class: 'card solve' }, body

  stat = (label, value, note) ->
    el 'div', { class: 'stat' }, [
      el 'div', { class: 'stat-value', text: value }
      el 'div', { class: 'stat-label', text: label }
      (if note then el 'div', { class: 'stat-note', text: note } else null)
    ]

  statsRow = ->
    placed = 0
    for entry in grid!
      placed += (entry.courses or []).length
    el 'div', { class: 'stats' }, [
      stat 'Banked college credit', String(report.banked or 0), 'estimate'
      stat 'Graduation credits missing', String(report.remaining), null
      stat 'Courses placed', String(placed), null
    ]

  checkLine = ->
    return el 'p', { class: 'check-line issues', text: "The rule check is not answering: #{checkNote}" } if checkNote?
    return null unless report?
    count = report.issues.length
    return el 'p', { class: 'check-line ok', text: 'Every placement passes the rules in the specsheet.' } if count is 0
    word = if count is 1 then 'rule issue' else 'rule issues'
    el 'p', { class: 'check-line issues', text: "#{count} #{word} marked in the grid. Nothing is blocked: you may know an exception the catalog does not, so take a marked placement to a counselor." }

  bankedNote = ->
    el 'p', { class: 'muted small' }, [
      'The banked-credit number is an estimate from '
      el 'a', { href: 'data/registry/exams.yaml', target: '_blank', rel: 'noopener', text: 'registry/exams.yaml' }
      '. A college transfer table is the authority; confirm before you rely on it.'
    ]

  gridCard = ->
    parts = []
    parts.push statsRow! if report?
    parts.push checkLine!
    parts.push el 'h2', { text: 'Term by term' }
    parts.push el 'p', { class: 'muted small', text: 'Drag courses from the catalog into terms; a summer drop opts that term in. Drag a course to another term to move it, or out of the grid (or press its x) to take it off. A placement that breaks a school rule gets a marker, never a refusal.' }
    parts.push gridEl!
    parts.push dropAway!
    parts.push bankedNote! if report?
    parts.push el 'h2', { text: 'Graduation requirements' }
    parts.push checklist!
    el 'div', { class: 'card plan' }, parts

  # --- the term grid ------------------------------------------------------

  # HS credits in a cell: a dual-enrollment course counts its fixed
  # graduation credit here, not the college credits it banks.
  creditsIn = (ids) ->
    credits = 0
    for id in ids
      course = ctx.catalog.byId[id]
      continue unless course?
      credits += if course.grad_credits? then course.grad_credits else (course.credits or 0)
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
        at[stem] = {} unless at[stem]?
        at[stem][half] = column
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

  planChip = (id, stems, chipIssues) ->
    stem = ctx.pairs.stemOf[id]
    linked = stem? and stem in stems
    partner = ctx.pairs.partnerOf[id]
    options = {
      why: whyUi.marker ctx, whyFor id
      onRemove: !-> removeFrom id
      removeTitle: 'Take this course off the grid'
      drag: { kind: 'plan', id: id }
    }
    details = chipIssues?[id]
    options.issue = { title: details.join '; ' } if details?
    if linked
      options.half = ctx.pairs.halfOf[id]
      options.title = "One course across two terms with #{partner}; they move together"
    chips.chip id, options

  # One term cell, always a drop target. Terms the "you are here"
  # marker puts behind the student keep their styling but stay
  # editable: the record itself is hand-built here.
  cell = (slot, entry, stems, chipIssues, termIssues, phase) ->
    ids = (entry?.courses) or []
    optedOut = slot.optional and not state.has 'optionalTerms', slot.key
    classes = ['grid-cell']
    classes.push 'empty' unless ids.length
    classes.push 'optional' if slot.optional
    classes.push 'optout' if optedOut
    if phase?
      classes.push 'past'
      classes.push phase
    kids = [el 'div', { class: 'cell-label', text: slot.label }]
    kids.push el 'div', { class: 'cell-phase', text: PHASE_LABEL[phase] or phase } if phase?
    if termIssues?
      line = termIssues.join '; '
      kids.push el 'div', { class: 'cell-issues', title: line, text: line }
    if ids.length
      kids.push el 'div', { class: 'chips' }, [planChip id, stems, chipIssues for id in ordered ids, stems]
      kids.push cellTotal ids
    else
      hint = if optedOut then 'optional; a drop here opts this term in' else 'empty'
      kids.push el 'p', { class: 'muted small', text: hint }
    node = el 'div', { class: classes.join ' ' }, kids
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
      place held.id, slot.grade, slot.term
    node

  gradeRow = (grade, columns, byKey, slotByKey, issues, order, cut) ->
    stems = rowStems grade, columns, byKey
    cells = [el 'div', { class: 'grid-grade', text: "Grade #{grade}" }]
    for term in columns
      key = "#{grade}:#{term}"
      slot = slotByKey[key] or { grade: grade, term: term, optional: false, key: key, label: "Grade #{grade} #{term}" }
      phase = null
      if cut >= 0 and order[key]?
        phase = 'done' if order[key] < cut
        phase = 'now' if order[key] is cut
      cells.push cell slot, byKey[key], stems, issues.byChip[key], issues.byTerm[key], phase
    el 'div', { class: 'grid-row' }, cells

  # Where a course goes when it is dragged off the grid.
  dropAway = ->
    zone = el 'div', {
      class: 'dropzone'
      text: 'Drop a course here to take it off the grid'
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
      removeFrom held.id
    zone

  gridEl = ->
    byKey = {}
    for entry in grid!
      byKey[termKey entry] = entry
    slotByKey = {}
    for slot in catalog.termSlots ctx.school
      slotByKey[slot.key] = slot
    issues = issueIndex!
    order = standing.orderIndex ctx.school
    cut = standing.markerIndex ctx.school, state.now!
    columns = catalog.termIds ctx.school
    head = [el 'div', { class: 'grid-corner' }]
    for term in columns
      head.push el 'div', { class: 'grid-term', text: term }
    rows = [el 'div', { class: 'grid-head' }, head]
    for grade in (ctx.school.grade_levels or [])
      rows.push gradeRow grade, columns, byKey, slotByKey, issues, order, cut
    el 'div', { class: 'grid', style: "--terms: #{columns.length}" }, rows

  # --- graduation requirements --------------------------------------------

  # Courses satisfying a requirement's predicate, split into what the
  # grid places and what the student already holds.
  coursesMatching = (req) ->
    planned = []
    for entry in grid!
      for id in (entry.courses or [])
        course = ctx.catalog.byId[id]
        planned.push id if course? and (reqMatches req, course) and id not in planned
    history = []
    profile = ctx.profile!
    pool = profile.completed ++ profile.inProgress
    pool = pool ++ profile.preHsCompleted if ctx.school.pre_hs_credit?.counts_toward_grad
    for id in pool
      course = ctx.catalog.byId[id]
      history.push id if course? and (reqMatches req, course) and id not in history
    { planned: planned, history: history }

  # One row per requirement, its progress driven by the rule check of
  # whatever the grid currently holds, hand-built or solver-produced.
  requirementRow = (req, tracked) ->
    earned = tracked?.have or 0
    counted = Math.min earned, req.credits
    ratio = if req.credits > 0 then counted / req.credits else 1
    covering = coursesMatching req
    detail = [el 'p', { class: 'muted small', text: 'Courses that cover it' }]
    detail.push el 'div', { class: 'chips' }, [chips.chip id for id in covering.planned]
    if covering.history.length
      detail.push el 'p', { class: 'muted small', text: 'Already on your record' }
      detail.push el 'div', { class: 'chips' }, [chips.chip id for id in covering.history]
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

  checklist = ->
    requirements = ctx.school.grad_requirements or []
    unless requirements.length
      return el 'p', { class: 'muted', text: 'This specsheet states no graduation requirements.' }
    byId = {}
    for tracked in ((report?.requirements) or [])
      byId[tracked.id] = tracked
    el 'div', { class: 'checklist' }, [requirementRow req, byId[req.id] for req in requirements]

  render!
  schedule!
  {
    el: root, refresh: refresh, show: show, running: running, failed: failed,
    stopped: stopped, hints: setHints, applyReport: applyReport,
    checkFailed: checkFailed, whyFor: whyFor, terms: terms,
    snapshot: snapshot, place: place, removeFrom: removeFrom,
    placedIn: placedIn
  }

module.exports = { create, diffText }
