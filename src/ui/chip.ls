# Course chips and the searchable course picker. A chip is the app's one
# way of naming a course: it shows the id, the name, and the level, and it
# opens the catalog entry so every course on screen links to its source.
# In a plan it also carries why the engine put it there, whether it is
# half of an A/B pair, and the drag handle that moves or drops it.

{ el, fill } = require './dom'
catalog = require './catalog'
drag = require './drag'

MAX_ROWS = 40

create = (ctx) ->

  label = (id) ->
    course = ctx.catalog.byId[id]
    if course? then course.name else 'not in this catalog'

  # The small marker saying why a course is in the plan. The dot carries
  # the full reasons as its tooltip; the word appears on wide screens.
  marker = (why) ->
    el 'span', { class: "why why-#{why.kind}", title: why.title }, [
      el 'span', { class: 'why-dot' }
      el 'span', { class: 'why-label', text: why.label }
    ]

  draggable = (node, payload) !->
    node.setAttribute 'draggable', 'true'
    node.addEventListener 'dragstart', (event) !->
      drag.begin payload
      if event.dataTransfer?
        event.dataTransfer.effectAllowed = 'copyMove'
        try event.dataTransfer.setData 'text/plain', payload.id
    node.addEventListener 'dragend', !-> drag.end!

  chip = (id, options) ->
    opts = options or {}
    course = ctx.catalog.byId[id]
    level = if course? then catalog.levelOf course else 'unknown'
    main = [
      el 'span', { class: 'chip-id', text: id }
      el 'span', { class: 'chip-name', text: label id }
      el 'span', { class: "badge level-#{level}", text: level }
    ]
    main.push marker opts.why if opts.why?
    # a rule the placement breaks: marked, never blocked, so the detail
    # rides on the marker's tooltip
    if opts.issue?
      main.push el 'span', { class: 'issue-mark', title: opts.issue.title }, [
        el 'span', { class: 'issue-dot' }
        el 'span', { class: 'issue-label', text: 'check' }
      ]
    parts = [
      el 'button', {
        class: 'chip-main'
        title: opts.title or 'Open the catalog entry'
        onclick: !-> ctx.openCourse id
      }, main
    ]
    if opts.onRemove?
      parts.push el 'button', {
        class: 'chip-x'
        title: opts.removeTitle or 'Remove'
        'aria-label': "#{opts.removeTitle or 'Remove'} #{id}"
        text: 'x'
        onclick: opts.onRemove
      }
    classes = ['chip']
    classes.push opts.flag if opts.flag
    classes.push "why-#{opts.why.kind}" if opts.why?
    classes.push 'has-issue' if opts.issue?
    classes.push "half half-#{opts.half}" if opts.half?
    # a dual-enrollment course, taken at the partner college
    classes.push 'college' if course?.college?
    node = el 'span', { class: classes.join ' ' }, parts
    draggable node, opts.drag if opts.drag?
    node

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
      row = el 'div', { class: 'picker-row' }, [
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
      draggable row, { kind: 'pick', id: course.id } if opts.draggable
      row

    input.addEventListener 'input', render
    render!
    { el: (el 'div', { class: 'picker' }, [input, rows, count]), refresh: render }

  { chip, picker, label }

module.exports = { create }
