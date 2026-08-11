# Plan rendering: the term grid, the graduation checklist, the engine's
# warnings, and the difference between one plan and the top plan. Every
# number here comes from the engine; nothing is recomputed except the
# per-cell totals and the plan-to-plan diff.

{ el, fill } = require './dom'
{ reqMatches } = require '../engine/gradreqs'
catalog = require './catalog'

OBJECTIVE_LABEL =
  max_credits: 'Bank the most college credit'
  early_grad: 'Graduate high school early'

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
  stale = false

  name = (id) ->
    course = ctx.catalog.byId[id]
    if course? then "#{id} #{course.name}" else id

  courseChip = (id) -> chips.chip id

  warningItem = (warning) -> el 'li', { text: warning }

  phaseText = (phase) ->
    switch phase
    | 'loading' => 'Loading the specsheet and the registries.'
    | 'embeddings' => 'Loading the course vectors for your goal.'
    | 'building' => 'Building the prerequisite graph.'
    | 'searching' => 'Searching term by term. This takes a few seconds.'
    | 'scoring' => 'Ranking the plans that survived.'
    | otherwise => 'Working.'

  # --- states ------------------------------------------------------------

  idle = !->
    latest := null
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
    selected := 0
    stale := false
    render!

  markStale = !->
    return unless latest?
    return if stale
    stale := true
    render!

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
    plan = result.plans[selected]
    parts = []
    parts.push summaryCard result
    parts.push warningCard result.warnings if result.warnings.length
    parts.push noticeCard result.notice if result.notice
    parts.push staleCard! if stale
    parts.push goalLine result if result.goalSource?
    parts.push tabs result
    parts.push planCard result, plan
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
      else 'encoded for this plan'
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
    for plan, i in result.plans
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

  planCard = (result, plan) ->
    parts = []
    parts.push el 'div', { class: 'stats' }, [
      stat 'Banked college credit', String(plan.banked), 'estimate'
      stat 'Graduation credits missing', String(plan.gradRemaining), null
      stat 'Terms used', String(plan.terms.length), null
      stat 'Plan score', plan.soft.toFixed(2), 'soft ranking'
    ]
    parts.push bankedNote!
    if selected > 0
      parts.push el 'p', { class: 'diff', text: "Plan #{selected + 1} #{diffText result.plans[0], plan, name}." }
    parts.push el 'h2', { text: 'Term by term' }
    parts.push grid plan
    parts.push el 'h2', { text: 'Graduation requirements' }
    parts.push checklist plan
    el 'div', { class: 'card plan' }, parts

  cell = (grade, term, entry) ->
    unless entry?
      return el 'div', { class: 'grid-cell empty' }, [
        el 'div', { class: 'cell-label', text: "Grade #{grade} #{term}" }
        el 'p', { class: 'muted small', text: 'not in this plan' }
      ]
    credits = 0
    for id in entry.courses
      course = ctx.catalog.byId[id]
      credits += (course?.credits or 0)
    el 'div', { class: 'grid-cell' }, [
      el 'div', { class: 'cell-label', text: "Grade #{grade} #{term}" }
      el 'div', { class: 'chips' }, [courseChip id for id in entry.courses]
      el 'div', { class: 'cell-total', text: "#{catalog.creditsLabel credits} credits, #{entry.courses.length} courses" }
    ]

  gradeRow = (grade, columns, byKey) ->
    cells = [el 'div', { class: 'grid-grade', text: "Grade #{grade}" }]
    for term in columns
      cells.push cell grade, term, byKey["#{grade}:#{term}"]
    el 'div', { class: 'grid-row' }, cells

  grid = (plan) ->
    byKey = {}
    for entry in plan.terms
      byKey[termKey entry] = entry
    columns = catalog.termIds ctx.school
    head = [el 'div', { class: 'grid-corner' }]
    for term in columns
      head.push el 'div', { class: 'grid-term', text: term }
    rows = [el 'div', { class: 'grid-head' }, head]
    for grade in (ctx.school.grade_levels or [])
      rows.push gradeRow grade, columns, byKey
    el 'div', { class: 'grid', style: "--terms: #{columns.length}" }, rows

  # Courses satisfying a requirement's predicate (tag, course list, or
  # content group), split into what the plan schedules and what the
  # profile already held.
  coursesMatching = (plan, req) ->
    planned = []
    for entry in plan.terms
      for id in entry.courses
        course = ctx.catalog.byId[id]
        planned.push id if course? and reqMatches req, course
    history = []
    profile = ctx.profile!
    pool = profile.completed ++ profile.inProgress
    pool = pool ++ profile.preHsCompleted if ctx.school.pre_hs_credit?.counts_toward_grad
    for id in pool
      course = ctx.catalog.byId[id]
      history.push id if course? and reqMatches req, course
    { planned: planned, history: history }

  requirementRow = (req, plan) ->
    earned = plan.coverage[req.id] or 0
    counted = Math.min earned, req.credits
    ratio = if req.credits > 0 then counted / req.credits else 1
    covering = coursesMatching plan, req
    detail = [
      el 'summary', { text: 'Courses that cover it' }
      el 'div', { class: 'chips' }, [courseChip id for id in covering.planned]
    ]
    if covering.history.length
      detail.push el 'p', { class: 'muted small', text: 'Already on your record' }
      detail.push el 'div', { class: 'chips' }, [courseChip id for id in covering.history]
    detail.push el 'p', { class: 'muted small', text: req.notes } if req.notes
    detail.push el 'p', { class: 'muted small' }, [
      "Requirement #{req.id} in "
      el 'a', { href: ctx.sourcePath, target: '_blank', rel: 'noopener', text: ctx.sourcePath }
      '.'
    ]
    el 'div', { class: if counted >= req.credits then 'req met' else 'req short' }, [
      el 'div', { class: 'req-head' }, [
        el 'span', { class: 'req-label', text: req.label }
        el 'span', { class: 'req-count', text: "#{catalog.creditsLabel counted} of #{catalog.creditsLabel req.credits} credits" }
      ]
      el 'div', { class: 'bar' }, [el 'div', { class: 'bar-fill', style: "width: #{Math.round ratio * 100}%" }]
      el 'details', { class: 'req-detail' }, detail
    ]

  checklist = (plan) ->
    requirements = ctx.school.grad_requirements or []
    unless requirements.length
      return el 'p', { class: 'muted', text: 'This specsheet states no graduation requirements.' }
    rows = []
    for req in requirements
      rows.push requirementRow req, plan
    el 'div', { class: 'checklist' }, rows

  idle!
  { el: root, idle: idle, running: running, show: show, failed: failed, markStale: markStale }

module.exports = { create, diffText }
