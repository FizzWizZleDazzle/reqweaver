# The profile editor: everything the student tells the planner. Each
# section owns a piece of the profile, writes it straight to state (which
# persists on every change), and refreshes in place, so course pickers keep
# their filter text and a slider keeps the pointer that is dragging it.

{ el, fill } = require './dom'
catalog = require './catalog'
state = require './state'

OBJECTIVES = [
  { id: 'max_credits', label: 'Bank the most college credit' }
  { id: 'early_grad', label: 'Graduate high school early' }
]

EFFORTS = [
  { value: 25, label: 'Quick (beam 25)' }
  { value: 100, label: 'Standard (beam 100)' }
  { value: 250, label: 'Thorough (beam 250)' }
]

rigorText = (value) ->
  wording =
    | value <= 0.2 => 'the gentlest track that still meets requirements'
    | value <= 0.45 => 'a moderate track'
    | value <= 0.7 => 'a demanding track'
    | otherwise => 'the most intense variant prerequisites allow'
  "#{value}: #{wording}"

create = (ctx) ->
  chips = ctx.chips
  sections = []

  # A titled block whose body is rebuilt by its own refresh function.
  block = (title, help, build) ->
    body = el 'div', { class: 'section-body' }
    node = el 'section', { class: 'section' }, [
      el 'h2', { text: title }
      (if help then el 'p', { class: 'muted small', text: help } else null)
      body
    ]
    sections.push build body
    node

  removableChip = (field, id) ->
    chips.chip id, { onRemove: !-> state.remove field, id }

  pinnedChip = (entry, id) ->
    chips.chip id, { onRemove: !-> state.removePin entry.grade, entry.term, id }

  slotOption = (slot) -> el 'option', { value: slot.key, text: slot.label }

  # A course list with a searchable picker under it.
  standing = (field, title, help) ->
    block title, help, (body) ->
      list = el 'div', { class: 'chips' }
      picker = chips.picker {
        chosen: (id) -> state.has field, id
        onPick: (id) !-> state.setStanding id, field
      }
      body.appendChild list
      body.appendChild el 'details', { class: 'adder' }, [
        el 'summary', { text: 'Add a course' }
        picker.el
      ]
      !->
        ids = state.profile![field]
        if ids.length
          fill list, [removableChip field, id for id in ids]
        else
          fill list, [el 'p', { class: 'muted small', text: 'Nothing yet.' }]
        picker.refresh!

  panel = el 'div', { class: 'panel' }

  panel.appendChild standing 'completed', 'Completed courses',
    'Courses you finished in grade 9 or later. They satisfy prerequisites and count toward graduation.'

  panel.appendChild standing 'preHsCompleted', 'Completed before grade 9',
    'Middle school credit. It always satisfies prerequisites; whether it also counts toward graduation is school policy.'

  panel.appendChild standing 'inProgress', 'In progress now',
    'Courses you are taking this term. The planner treats them as done and plans around them.'

  # --- terms and load ------------------------------------------------------

  optionalCheck = (slot) ->
    el 'label', { class: 'check' }, [
      el 'input', {
        type: 'checkbox'
        checked: state.has 'optionalTerms', slot.key
        onchange: !-> state.toggle 'optionalTerms', slot.key
      }
      el 'span', { text: slot.label }
    ]

  panel.appendChild block 'Terms',
    'Optional terms join your plan only where you opt in. A summer term is the fastest way to pull a whole sequence forward.',
    (body) ->
      optional = [slot for slot in catalog.termSlots(ctx.school) when slot.optional]
      list = el 'div', { class: 'checks' }
      cap = el 'input', {
        id: 'cap'
        class: 'input'
        type: 'number'
        min: '1'
        max: '12'
        placeholder: "school cap: #{ctx.school.max_courses_per_term or 'none'}"
        onchange: (event) !->
          raw = event.target.value
          state.setField 'maxCoursesPerTerm', (if raw is '' then null else Number raw)
      }
      body.appendChild list
      body.appendChild el 'div', { class: 'field' }, [
        el 'label', { for: 'cap', text: 'Your own limit on courses per term' }
        cap
      ]
      !->
        if optional.length
          fill list, [optionalCheck slot for slot in optional]
        else
          fill list, [el 'p', { class: 'muted small', text: 'This school has no optional terms.' }]
        limit = state.profile!.maxCoursesPerTerm
        wanted = if limit? then String limit else ''
        cap.value = wanted if cap.value isnt wanted and document.activeElement isnt cap

  # --- pins ----------------------------------------------------------------

  pinRow = (entry) ->
    el 'div', { class: 'pin-row' }, [
      el 'div', { class: 'pin-term', text: "Grade #{entry.grade} #{entry.term}" }
      el 'div', { class: 'chips' }, [pinnedChip entry, id for id in entry.courses]
    ]

  panel.appendChild block 'Pinned courses',
    'A pin is an override. The planner always honors it, and reports any school rule it breaks as a warning to take to a counselor.',
    (body) ->
      list = el 'div', { class: 'pin-list' }
      slots = catalog.termSlots ctx.school
      select = el 'select', { class: 'select' }, [slotOption slot for slot in slots]
      picker = chips.picker {
        placeholder: 'Search the course to pin'
        chosen: (id) -> state.pinnedTerm(id)?
        onPick: (id) !->
          parts = select.value.split ':'
          state.addPin (Number parts[0]), parts[1], id
      }
      body.appendChild list
      body.appendChild el 'details', { class: 'adder' }, [
        el 'summary', { text: 'Pin a course to a term' }
        el 'div', { class: 'field' }, [el 'label', { text: 'Term' }, select]
        picker.el
      ]
      !->
        entries = state.profile!.pinned
        if entries.length
          fill list, [pinRow entry for entry in entries]
        else
          fill list, [el 'p', { class: 'muted small', text: 'Nothing pinned.' }]
        picker.refresh!

  # --- waivers -------------------------------------------------------------

  panel.appendChild block 'Waivers',
    'Courses whose prerequisites your school has excused (placement test, teacher recommendation). Every other rule still applies to them.',
    (body) ->
      list = el 'div', { class: 'chips' }
      picker = chips.picker {
        placeholder: 'Search the waived course'
        chosen: (id) -> state.has 'waivers', id
        onPick: (id) !-> state.add 'waivers', id
      }
      body.appendChild list
      body.appendChild el 'details', { class: 'adder' }, [
        el 'summary', { text: 'Add a waiver' }
        picker.el
      ]
      !->
        ids = state.profile!.waivers
        if ids.length
          fill list, [removableChip 'waivers', id for id in ids]
        else
          fill list, [el 'p', { class: 'muted small', text: 'No waivers.' }]
        picker.refresh!

  # --- preferences ---------------------------------------------------------

  objectiveButton = (item) ->
    el 'button', {
      class: if state.profile!.objective is item.id then 'choice active' else 'choice'
      text: item.label
      onclick: !-> state.setField 'objective', item.id
    }

  tagChip = (tag) ->
    el 'button', {
      class: if tag in state.profile!.interests then 'tag active' else 'tag'
      text: tag
      onclick: !-> state.toggle 'interests', tag
    }

  effortOption = (item) -> el 'option', { value: String(item.value), text: item.label }

  panel.appendChild block 'What you want', null, (body) ->
    tagList = catalog.tags ctx.school
    goal = el 'input', {
      class: 'input goal'
      type: 'text'
      placeholder: 'quantum theory and theoretical physics research'
      oninput: (event) !-> state.setField 'goal', event.target.value
    }
    objective = el 'div', { class: 'choices' }
    interests = el 'div', { class: 'chips tag-chips' }
    rigorNote = el 'p', { class: 'muted small' }
    rigor = el 'input', {
      class: 'range'
      type: 'range'
      min: '0'
      max: '1'
      step: '0.05'
      oninput: (event) !-> state.setField 'rigor', Number event.target.value
    }
    effort = el 'select', { class: 'select', onchange: (event) !-> state.setUi 'beam', Number event.target.value },
      [effortOption item for item in EFFORTS]
    body.appendChild el 'h3', { text: 'Goal' }
    body.appendChild el 'p', { class: 'muted small', text: 'A sentence about what you want to study. Courses whose catalog descriptions match it rank higher. Wording a school precompiled always works; anything else is read by the encoding service, and the plan says when it could not be.' }
    body.appendChild goal
    body.appendChild el 'h3', { text: 'Objective' }
    body.appendChild objective
    body.appendChild el 'h3', { text: 'Rigor' }
    body.appendChild rigor
    body.appendChild rigorNote
    body.appendChild el 'h3', { text: 'Interests' }
    body.appendChild el 'p', { class: 'muted small', text: "Tags this school's catalog uses. Spare capacity goes toward the ones you pick." }
    body.appendChild interests
    body.appendChild el 'h3', { text: 'Search effort' }
    body.appendChild effort
    body.appendChild el 'p', { class: 'muted small', text: 'A wider beam explores more plans and takes longer.' }
    !->
      p = state.profile!
      goal.value = (p.goal or '') unless document.activeElement is goal
      fill objective, [objectiveButton item for item in OBJECTIVES]
      fill interests, [tagChip tag for tag in tagList]
      rigor.value = String p.rigor unless document.activeElement is rigor
      rigorNote.textContent = rigorText p.rigor
      effort.value = String state.ui!.beam

  # --- the profile file ----------------------------------------------------

  panel.appendChild block 'Your profile file',
    'Everything here stays in this browser. Export writes the same YAML the command line planner reads.',
    (body) ->
      area = el 'textarea', { class: 'yaml', rows: '10', spellcheck: 'false', placeholder: 'Profile YAML appears here on export, and is read from here on import.' }
      status = el 'p', { class: 'muted small' }
      body.appendChild el 'div', { class: 'choices' }, [
        el 'button', {
          class: 'choice'
          text: 'Export'
          onclick: !->
            area.value = state.toYaml!
            status.textContent = 'Exported below. Copy it somewhere safe.'
        }
        el 'button', {
          class: 'choice'
          text: 'Import'
          onclick: !->
            try
              state.fromYaml area.value
              status.textContent = 'Imported.'
            catch error
              status.textContent = "Could not import: #{error.message}"
        }
        el 'button', {
          class: 'ghost'
          text: 'Reset profile'
          onclick: !->
            if window.confirm 'Clear the whole profile? This cannot be undone.'
              state.reset!
              area.value = ''
              status.textContent = 'Profile cleared.'
        }
      ]
      body.appendChild area
      body.appendChild status
      -> null

  refresh = !->
    for fn in sections
      fn!

  refresh!
  { el: panel, refresh: refresh }

module.exports = { create }
