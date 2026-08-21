# The form shown before the planner the first time a student arrives
# with an empty goal. One question per screen, because a page of
# sections is exactly what gets skimmed past: the student answers what
# is in front of them, presses next, and lands in the planner with a
# profile the plans can use. Every answer writes straight to the same
# profile state the editor reads, so the form and the profile tab can
# never disagree.

{ el, fill } = require './dom'
catalog = require './catalog'
state = require './state'
chipUi = require './chip'
profileUi = require './profile'

# Show the form only when the goal is still empty and the student has
# not been through it. The flag, not the answers, records that: a
# student who chose to skip is not asked again on every navigation.
needed = -> (not state.ui!.intakeDone) and not (state.profile!.goal or '').length

create = (school, onDone) ->
  # The picker and the chips need a catalog and an open-course hook;
  # the course dialog does not exist before the planner builds, so
  # opening is a no-op here and the chip is just a name.
  chips = chipUi.create { catalog: catalog.index(school), openCourse: (!-> null) }

  finish = !->
    state.setUi 'intakeDone', true
    onDone!

  # A step owns one question: a title, a line of help, and one control.
  # Its DOM is built once and kept, so a picker's filter text survives
  # going back and forth.
  steps = []
  step = (title, help, build) !->
    body = el 'div', { class: 'section-body' }
    refresh = build body
    steps.push { title: title, help: help, body: body, refresh: refresh }

  # A standing question: the chips already chosen, a searchable picker
  # under them. Same wiring as the profile editor's standing sections.
  standingStep = (field, title, help) !->
    step title, help, (body) ->
      list = el 'div', { class: 'chips' }
      picker = chips.picker {
        chosen: (id) -> state.has field, id
        onPick: (id) !->
          state.setStanding id, field
          refreshStep!
      }
      body.appendChild list
      body.appendChild picker.el
      !->
        ids = state.profile![field]
        if ids.length
          fill list, [chips.chip id, { onRemove: !->
            state.setStanding id, null
            refreshStep!
          } for id in ids]
        else
          fill list, [el 'p', { class: 'muted small', text: 'Nothing yet. Skip ahead if there is nothing to add.' }]
        picker.refresh!

  # --- the questions, in the order they are asked ---------------------------

  standingStep 'completed', 'What have you finished?',
    'Courses you completed in grade 9 or later. They satisfy prerequisites and count toward graduation.'

  standingStep 'preHsCompleted', 'Any credit from before grade 9?',
    'Middle school courses. They always satisfy prerequisites; whether they also count toward graduation is school policy.'

  standingStep 'inProgress', 'What are you taking right now?',
    'Courses in progress this term. The planner treats them as done and plans around them.'

  step 'What do you want to study?',
    'A sentence about where you are heading. Courses whose catalog descriptions match it rank higher; without it, plans ignore your direction.',
    (body) ->
      goal = el 'input', {
        class: 'input goal'
        type: 'text'
        placeholder: 'quantum theory and theoretical physics research'
        oninput: (event) !-> state.setField 'goal', event.target.value
      }
      body.appendChild goal
      !->
        goal.value = (state.profile!.goal or '') unless document.activeElement is goal

  step 'What should a plan aim for?', null, (body) ->
    choices = el 'div', { class: 'choices' }
    body.appendChild choices
    button = (item) ->
      el 'button', {
        class: if state.profile!.objective is item.id then 'choice active' else 'choice'
        text: item.label
        onclick: !->
          state.setField 'objective', item.id
          refreshStep!
      }
    !-> fill choices, [button item for item in profileUi.OBJECTIVES]

  step 'How hard do you want the road to be?', null, (body) ->
    note = el 'p', { class: 'muted small' }
    rigor = el 'input', {
      class: 'range'
      type: 'range'
      min: '0'
      max: '1'
      step: '0.05'
      oninput: (event) !->
        state.setField 'rigor', Number event.target.value
        refreshStep!
    }
    body.appendChild rigor
    body.appendChild note
    !->
      rigor.value = String state.profile!.rigor unless document.activeElement is rigor
      note.textContent = profileUi.rigorText state.profile!.rigor

  tagList = catalog.tags school
  tagStep = (field, title, help, extraClass) !->
    step title, help, (body) ->
      list = el 'div', { class: 'chips tag-chips' }
      body.appendChild list
      button = (tag) ->
        active = tag in (state.profile![field] or [])
        el 'button', {
          class: if active then "tag active#{extraClass}" else 'tag'
          text: tag
          onclick: !->
            state.toggle field, tag
            refreshStep!
        }
      !-> fill list, [button tag for tag in tagList]

  tagStep 'interests', 'What are you into?',
    "Tags this school's catalog uses. Spare capacity goes toward the ones you pick.", ''

  tagStep 'dislikes', 'Anything you would rather keep light?',
    'Requirements in these subjects still get covered, with the gentlest course that counts, and nothing extra.', ' dislike'

  # --- the wizard around them -----------------------------------------------

  current = 0
  progress = el 'p', { class: 'muted small' }
  title = el 'h2'
  help = el 'p', { class: 'muted small' }
  slot = el 'div', { class: 'intake-slot' }
  back = el 'button', { class: 'ghost', text: 'Back', onclick: !-> show current - 1 }
  next = el 'button', { class: 'choice active', onclick: !->
    if current < steps.length - 1 then show current + 1 else finish!
  }
  skip = el 'button', { class: 'ghost', text: 'Skip the rest', onclick: finish }

  refreshStep = !-> steps[current].refresh!

  show = (wanted) !->
    current := if wanted < 0 then 0 else if wanted >= steps.length then steps.length - 1 else wanted
    entry = steps[current]
    progress.textContent = "Question #{current + 1} of #{steps.length}"
    title.textContent = entry.title
    help.textContent = entry.help or ''
    help.classList.toggle 'hidden', not entry.help?
    fill slot, [entry.body]
    entry.refresh!
    back.disabled = current is 0
    next.textContent = if current < steps.length - 1 then 'Next' else 'Start planning'
    skip.classList.toggle 'hidden', current is steps.length - 1

  node = el 'section', { class: 'card intake' }, [
    el 'p', { class: 'muted', text: "A few questions before you plan at #{school.name or ''}. Everything here can be changed later under the \"Your profile\" tab." }
    progress
    title
    help
    slot
    el 'div', { class: 'choices intake-nav' }, [back, next, skip]
  ]

  show 0
  { el: node }

module.exports = { needed, create }
