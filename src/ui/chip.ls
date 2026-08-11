# Course chips and the searchable course picker. A chip is the app's one
# way of naming a course: it shows the id, the name, and the level, and it
# opens the catalog entry so every course on screen links to its source.

{ el, fill } = require './dom'
catalog = require './catalog'

MAX_ROWS = 40

create = (ctx) ->

  label = (id) ->
    course = ctx.catalog.byId[id]
    if course? then course.name else 'not in this catalog'

  chip = (id, options) ->
    opts = options or {}
    course = ctx.catalog.byId[id]
    level = if course? then catalog.levelOf course else 'unknown'
    parts = [
      el 'button', {
        class: 'chip-main'
        title: 'Open the catalog entry'
        onclick: !-> ctx.openCourse id
      }, [
        el 'span', { class: 'chip-id', text: id }
        el 'span', { class: 'chip-name', text: label id }
        el 'span', { class: "badge level-#{level}", text: level }
      ]
    ]
    if opts.onRemove?
      parts.push el 'button', {
        class: 'chip-x'
        title: 'Remove'
        'aria-label': "Remove #{id}"
        text: 'x'
        onclick: opts.onRemove
      }
    el 'span', { class: if opts.flag then "chip #{opts.flag}" else 'chip' }, parts

  # Filter-as-you-type over the whole catalog. The input element is kept
  # across refreshes so typing never loses focus or text.
  picker = (options) ->
    opts = options or {}
    input = el 'input', {
      class: 'search'
      type: 'search'
      placeholder: opts.placeholder or 'Search courses by id or name'
      autocomplete: 'off'
    }
    rows = el 'div', { class: 'picker-rows' }
    count = el 'p', { class: 'muted small' }

    render = !->
      pool = if opts.pool? then opts.pool! else ctx.catalog.list
      matches = catalog.filter pool, input.value, MAX_ROWS
      fill rows, [rowFor course for course in matches]
      total = pool.length
      if matches.length is 0
        count.textContent = 'No course matches that.'
      else
        count.textContent = "Showing #{matches.length} of #{total} courses."

    rowFor = (course) ->
      chosen = opts.chosen? and opts.chosen course.id
      el 'div', { class: 'picker-row' }, [
        el 'button', {
          class: if chosen then 'picker-add chosen' else 'picker-add'
          text: if chosen then 'Added' else 'Add'
          onclick: !->
            opts.onPick course.id
            render!
        }
        el 'button', {
          class: 'picker-label'
          title: 'Open the catalog entry'
          onclick: !-> ctx.openCourse course.id
        }, [
          el 'span', { class: 'chip-id', text: course.id }
          el 'span', { class: 'chip-name', text: course.name }
          el 'span', { class: "badge level-#{catalog.levelOf course}", text: catalog.levelOf course }
        ]
      ]

    input.addEventListener 'input', render
    render!
    { el: (el 'div', { class: 'picker' }, [input, rows, count]), refresh: render }

  { chip, picker, label }

module.exports = { create }
