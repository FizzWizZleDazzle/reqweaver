# The catalog panel: every course the school offers, searchable and
# grouped by department, each row draggable into the term grid. The
# specsheets carry no department field, so the first tag on a course is
# the department; the tag vocabulary is the school's own. A row also
# opens the course dialog, so the full catalog entry is one click away.

{ el, fill } = require './dom'
catalog = require './catalog'
drag = require './drag'

SEARCH_LIMIT = 60

groupLabel = (tag) -> String(tag).replace /_/g, ' '

# Courses bucketed by their first tag; a course with no tags lands
# under "other". Merged partner-college courses get one group per
# college, after the departments, named by collegeLabel.
groupsOf = (list, collegeLabel) ->
  byTag = {}
  for course in list
    tag = if course.college? then "college:#{course.college}" else ((course.tags or [])[0] or 'other')
    byTag[tag] = [] unless byTag[tag]?
    byTag[tag].push course
  departments = [name for name in Object.keys(byTag) when name.indexOf('college:') isnt 0].sort!
  partners = [name for name in Object.keys(byTag) when name.indexOf('college:') is 0].sort!
  out = [{ tag: name, label: groupLabel(name), courses: byTag[name] } for name in departments]
  for name in partners
    out.push { tag: name, label: collegeLabel(name.slice 'college:'.length), courses: byTag[name] }
  out

create = (ctx) ->
  collegeLabel = (id) -> "#{ctx.colleges?[id]?.name or id} - dual enrollment"
  # which department groups are unfolded, kept across re-renders
  openTags = {}

  draggable = (node, id) !->
    node.setAttribute 'draggable', 'true'
    node.addEventListener 'dragstart', (event) !->
      drag.begin { kind: 'pick', id: id }
      if event.dataTransfer?
        event.dataTransfer.effectAllowed = 'copyMove'
        try event.dataTransfer.setData 'text/plain', id
    node.addEventListener 'dragend', !-> drag.end!

  row = (course) ->
    placed = ctx.placedIn? course.id
    label = [
      el 'span', { class: 'chip-id', text: course.id }
      el 'span', { class: 'chip-name', text: course.name }
      el 'span', { class: "badge level-#{catalog.levelOf course}", text: catalog.levelOf course }
    ]
    label.push el 'span', { class: 'pill placed', text: "grade #{placed.grade} #{placed.term}" } if placed?
    node = el 'div', { class: 'picker-row draggable' }, [
      el 'button', {
        class: 'picker-label'
        title: 'Open the catalog entry'
        onclick: !-> ctx.openCourse course.id
      }, label
    ]
    draggable node, course.id
    node

  groupNode = (group) ->
    node = el 'details', {
      class: 'group'
      open: (if openTags[group.tag] then true else null)
    }, [
      el 'summary', {}, [
        el 'span', { class: 'group-name', text: group.label }
        el 'span', { class: 'muted small', text: "#{group.courses.length} courses" }
      ]
      el 'div', { class: 'picker-rows' }, [row course for course in group.courses]
    ]
    node.addEventListener 'toggle', !-> openTags[group.tag] = node.open
    node

  input = el 'input', {
    class: 'search'
    type: 'search'
    placeholder: 'Search courses by id or name'
    autocomplete: 'off'
    'aria-label': 'Search the catalog'
  }
  body = el 'div', { class: 'browse-body' }

  render = !->
    # regrouped every render: the catalog gains and loses the partner
    # college's courses with the dual-enrollment opt-in
    query = input.value.trim!
    unless query.length
      grouped = groupsOf ctx.catalog.list, collegeLabel
      return fill body, [groupNode group for group in grouped]
    matches = catalog.filter ctx.catalog.list, query, SEARCH_LIMIT
    unless matches.length
      return fill body, [el 'p', { class: 'muted small', text: 'No course matches that.' }]
    fill body, [
      el 'div', { class: 'picker-rows' }, [row course for course in matches]
      el 'p', { class: 'muted small', text: "Showing #{matches.length} of #{ctx.catalog.list.length} courses." }
    ]

  input.addEventListener 'input', render
  render!

  root = el 'section', { class: 'section browse' }, [
    el 'h2', { text: 'Course catalog' }
    el 'p', { class: 'muted small', text: 'Everything this school offers. Drag a course into a term on the grid, or click it to read its catalog entry.' }
    input
    body
  ]
  { el: root, refresh: render }

module.exports = { create }
