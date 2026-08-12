# Entry point and router. The path names what the page shows: / is the
# school chooser, /<school id> is the planner for that school, and
# /s/<code> is a saved plan, read only. Everything the planner does
# happens in the worker; this thread only builds DOM.

{ el, fill } = require './dom'
data = require './data'
state = require './state'
catalog = require './catalog'
pairs = require './pairs'
api = require './api'
schoolsUi = require './schools'
chipUi = require './chip'
courseUi = require './course'
profileUi = require './profile'
plansUi = require './plans'
browseUi = require './browse'
shareUi = require './share'
sharedUi = require './shared'
solverUi = require './solver'

TOP_PLANS = 3

# One subscription for the life of the page; navigating swaps what it
# calls rather than adding another listener.
active = { refresh: null, leave: null }

# The site is one Worker: the page, the data files, and the API sit on
# one origin, and a school's path is the page's path, so every fetch is
# root-relative (index.html carries <base href="/">).
segmentsOf = (path) -> [part for part in String(path or '/').split '/' when part.length]

pathFor = (id) -> "/#{id}"

fail = (root, message) !->
  fill root, [
    el 'div', { class: 'card error' }, [
      el 'h2', { text: 'reqweaver could not start' }
      el 'p', { text: message }
      el 'p', { class: 'muted small', text: 'Run npm run build:web, then serve the public directory.' }
    ]
  ]

brand = (tagline) ->
  el 'div', { class: 'brand' }, [
    el 'a', { class: 'wordmark', href: '/', text: 'reqweaver' }
    el 'span', { class: 'tagline', text: tagline }
  ]

# One school at a time: navigating to another rebuilds the whole page
# against the new specsheet. Landing here shows the catalog and the term
# grid at once, restored from the last visit; the solver only runs when
# asked.
build = (root, index, config, entry, school, levels) !->
  courses = catalog.index school
  openCourse = null
  run = null
  # One context object, shared by reference: components added later read
  # the callbacks the ones before them could not have.
  ctx = {
    school: school
    entry: entry
    config: config
    catalog: courses
    pairs: pairs.index school
    levels: levels
    sourcePath: entry.path
    profile: state.profile
    openCourse: (id) !-> openCourse id
    onCancel: !-> solver.cancel!
    rerun: !-> run!
  }

  chips = chipUi.create ctx
  ctx.chips = chips
  sheet = courseUi.create ctx
  openCourse := sheet.open

  planner = plansUi.create ctx
  # what the grid on screen says, for the course dialog, the catalog
  # panel, the profile export, and the save payload
  ctx.whyFor = planner.whyFor
  ctx.gridTerms = planner.terms
  ctx.snapshot = planner.snapshot
  ctx.place = planner.place
  ctx.removeFromGrid = planner.removeFrom
  ctx.placedIn = planner.placedIn
  ctx.validate = (job) !->
    checker.run { schoolPath: entry.path, profile: state.profile!, plan: job.plan }

  browse = browseUi.create ctx
  panel = profileUi.create ctx
  share = shareUi.create ctx

  solver = solverUi.create {
    status: (message) !-> planner.running message.phase
    done: (message) !-> planner.show message
    hints: (message) !-> planner.hints message.hints
    error: (message) !-> planner.failed message.message
    cancelled: !-> planner.stopped!
  }

  # The rule check behind the grid, on its own worker so a solve in
  # flight never delays it.
  checker = solverUi.validator {
    report: planner.applyReport
    error: planner.checkFailed
  }

  run := !->
    # the grid on screen, which the marker splits into what is already
    # standing and what is still open to planning
    shown = planner.terms!
    planner.running 'loading'
    solver.run {
      schoolPath: entry.path
      embeddingsPath: entry.embeddings or null
      # the goal encoder, on this origin unless siteconfig names another
      encodeApi: api.encodeUrl config
      profile: state.profile!
      standingPlan: shown
      beam: state.ui!.beam
      top: TOP_PLANS
    }

  picker = schoolsUi.typeahead index.schools, {
    current: -> entry.name or entry.id
    onPick: (chosen) !->
      return if chosen.id is entry.id
      go pathFor chosen.id
  }

  header = el 'header', { class: 'topbar' }, [
    brand 'plan high school around the college credit you want to bank'
    el 'div', { class: 'topbar-controls' }, [picker.el]
  ]

  footer = el 'footer', { class: 'footer' }, [
    el 'p', {}, [
      'Plans are proposals for a counselor, not a schedule. Course data comes from '
      el 'a', { href: entry.path, target: '_blank', rel: 'noopener', text: entry.path }
      ", catalog year #{school.catalog_year}. Unwritten local rules (approvals, seat limits, section times) are not modeled."
    ]
  ]

  # The left column switches between the catalog and the profile; both
  # stay mounted so pickers keep their filter text.
  catalogPane = el 'div', { class: 'pane' }, [browse.el]
  profilePane = el 'div', { class: 'pane hidden' }, [panel.el]
  catalogTab = el 'button', { class: 'tab active', text: 'Catalog' }
  profileTab = el 'button', { class: 'tab', text: 'Your profile' }
  setPane = (wanted) !->
    catalogTab.className = if wanted is 'catalog' then 'tab active' else 'tab'
    profileTab.className = if wanted is 'profile' then 'tab active' else 'tab'
    catalogPane.classList.toggle 'hidden', wanted isnt 'catalog'
    profilePane.classList.toggle 'hidden', wanted isnt 'profile'
  catalogTab.addEventListener 'click', !-> setPane 'catalog'
  profileTab.addEventListener 'click', !-> setPane 'profile'

  fill root, [
    header
    el 'main', { class: 'layout' }, [
      el 'div', { class: 'col-profile' }, [
        el 'div', { class: 'tabs paneswitch' }, [catalogTab, profileTab]
        catalogPane
        profilePane
      ]
      el 'div', { class: 'col-results' }, [planner.el, share.el]
    ]
    footer
    sheet.el
  ]

  active.refresh = !->
    panel.refresh!
    planner.refresh!
    browse.refresh!
    share.refresh!
  active.leave = !->
    solver.cancel!
    checker.stop!

chooser = (root, index, notice) !->
  recent = null
  for item in index.schools when item.id is state.schoolId!
    recent := item
  fill root, [
    el 'header', { class: 'topbar' }, [brand 'plan high school around the college credit you want to bank']
    el 'main', { class: 'layout single' }, [
      schoolsUi.chooser index.schools, {
        notice: notice
        recent: recent
        onPick: (chosen) !-> go pathFor chosen.id
      }
    ]
  ]

# --- routing ---------------------------------------------------------------

# The index, the deployment settings, and the registries are the same
# for every route, so they are fetched once for the life of the page.
ready = null

load = ->
  ready := Promise.all([data.loadIndex!, data.loadSiteConfig!, data.loadLevels!]) unless ready?
  ready

go = (path) !->
  if window.history?.pushState?
    window.history.pushState {}, '', path
  route!

route = !->
  root = document.getElementById 'app'
  return unless root?
  active.leave?!
  active.refresh = null
  active.leave = null
  parts = segmentsOf window.location?.pathname
  loading = load!.then (loaded) ->
    [index, config, levels] = loaded
    unless index.schools?.length
      throw new Error 'the data index lists no schools'
    if parts[0] is 's' and parts[1]?
      view = sharedUi.create { loadSchool: data.loadSchool }
      return view.open root, parts[1], config, index
    unless parts.length
      return chooser root, index, null
    wanted = parts.join '/'
    entry = null
    for item in index.schools when item.id is wanted
      entry := item
    unless entry?
      return chooser root, index, "No school in this build has the address /#{wanted}."
    state.setSchool entry.id unless entry.id is state.schoolId!
    data.loadSchool(entry).then (school) ->
      build root, index, config, entry, school, levels
  loading.catch (error) !->
    fail root, String(error?.message or error)

main = !->
  return unless document.getElementById 'app'
  state.load!
  state.subscribe !-> active.refresh?!
  window.addEventListener 'popstate', !-> route!
  route!

if document.readyState is 'loading'
  document.addEventListener 'DOMContentLoaded', main
else
  main!

module.exports = { main, segmentsOf }
