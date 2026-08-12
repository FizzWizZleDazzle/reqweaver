# Entry point: load the school index and one specsheet, wire the profile
# editor to the worker, and render what comes back. All planning happens in
# the worker; this thread only builds DOM.

{ el, fill } = require './dom'
data = require './data'
state = require './state'
catalog = require './catalog'
chipUi = require './chip'
courseUi = require './course'
profileUi = require './profile'
plansUi = require './plans'
solverUi = require './solver'

TOP_PLANS = 3

# One subscription for the life of the page; switching schools swaps what
# it calls rather than adding another listener.
active = { refresh: null }

schoolOption = (item) -> el 'option', { value: item.id, text: item.name }

fail = (root, message) !->
  fill root, [
    el 'div', { class: 'card error' }, [
      el 'h2', { text: 'reqweaver could not start' }
      el 'p', { text: message }
      el 'p', { class: 'muted small', text: 'Run npm run build:web, then serve the public directory.' }
    ]
  ]

# One school at a time: switching schools rebuilds the whole page against
# the new specsheet.
build = (root, index, config, entry, school, levels) !->
  courses = catalog.index school
  openCourse = null
  ctx = {
    school: school
    catalog: courses
    levels: levels
    sourcePath: entry.path
    profile: state.profile
    openCourse: (id) !-> openCourse id
  }

  chips = chipUi.create ctx
  ctx.chips = chips
  sheet = courseUi.create ctx
  openCourse := sheet.open

  runButton = el 'button', { class: 'primary', text: 'Run planner' }
  status = el 'span', { class: 'run-status muted small' }

  plans = plansUi.create ({ onCancel: !-> solver.cancel! } <<< ctx)
  panel = profileUi.create ctx

  setRunning = (on_, text) !->
    runButton.disabled = on_
    runButton.textContent = if on_ then 'Planning...' else 'Run planner'
    status.textContent = text or ''

  solver = solverUi.create {
    status: (message) !-> plans.running message.phase
    done: (message) !->
      setRunning false, "#{message.plans.length} plans shown, #{message.planCount} found"
      plans.show message
    error: (message) !->
      setRunning false, 'stopped'
      plans.failed message.message
    cancelled: !->
      setRunning false, 'cancelled'
      plans.idle!
  }

  run = !->
    setRunning true, ''
    plans.running 'loading'
    solver.run {
      schoolPath: entry.path
      embeddingsPath: entry.embeddings or null
      # the goal-encoding service, when siteconfig.yaml names one
      encodeApi: config.encode_api or null
      profile: state.profile!
      beam: state.ui!.beam
      top: TOP_PLANS
    }
    document.querySelector('.col-results')?.scrollIntoView { behavior: 'smooth', block: 'start' } if window.innerWidth < 900

  runButton.addEventListener 'click', run

  schoolSelect = el 'select', { class: 'select', 'aria-label': 'School' },
    [schoolOption item for item in index.schools]
  schoolSelect.value = entry.id
  schoolSelect.addEventListener 'change', !->
    state.setSchool schoolSelect.value
    solver.cancel!
    start root

  header = el 'header', { class: 'topbar' }, [
    el 'div', { class: 'brand' }, [
      el 'span', { class: 'wordmark', text: 'reqweaver' }
      el 'span', { class: 'tagline', text: 'plan high school around the college credit you want to bank' }
    ]
    el 'div', { class: 'topbar-controls' }, [schoolSelect, runButton, status]
  ]

  footer = el 'footer', { class: 'footer' }, [
    el 'p', {}, [
      'Plans are proposals for a counselor, not a schedule. Course data comes from '
      el 'a', { href: entry.path, target: '_blank', rel: 'noopener', text: entry.path }
      ", catalog year #{school.catalog_year}. Unwritten local rules (approvals, seat limits, section times) are not modeled."
    ]
  ]

  fill root, [
    header
    el 'main', { class: 'layout' }, [
      el 'div', { class: 'col-profile' }, [panel.el]
      el 'div', { class: 'col-results' }, [plans.el]
    ]
    footer
    sheet.el
  ]

  active.refresh = !->
    panel.refresh!
    plans.markStale!

start = (root) !->
  active.refresh = null
  loading = data.loadIndex!.then (index) ->
    unless index.schools?.length
      throw new Error 'the data index lists no schools'
    wanted = state.schoolId!
    entry = null
    for item in index.schools when item.id is wanted
      entry := item
    entry := index.schools[0] unless entry?
    state.setSchool entry.id unless entry.id is wanted
    Promise.all([data.loadSchool(entry), data.loadLevels!, data.loadSiteConfig!]).then (parts) !->
      build root, index, (parts[2] or {}), entry, parts[0], parts[1]
  loading.catch (error) !->
    fail root, String(error?.message or error)

main = !->
  root = document.getElementById 'app'
  return unless root?
  state.load!
  state.subscribe !-> active.refresh?!
  start root

if document.readyState is 'loading'
  document.addEventListener 'DOMContentLoaded', main
else
  main!

module.exports = { main }
