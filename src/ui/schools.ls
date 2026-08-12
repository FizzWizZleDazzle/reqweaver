# Choosing a school. The index is a flat list of { id, name, kind }, and
# the path names the school (/us/md/mcps/wchs), so choosing one is
# navigation. Search is a lowercase substring over the name, the id and
# the kind, scanned in one pass and cut off at a screenful, which stays
# quick with an index far larger than the page can show.

{ el, fill } = require './dom'

MAX_ROWS = 12

# id prefixes rank first, then a name that starts with the query, then
# everything else; ties break by name so the order never wobbles.
rankOf = (entry, query) ->
  id = String(entry.id or '').toLowerCase!
  name = String(entry.name or '').toLowerCase!
  if id.indexOf(query) is 0 then 0
  else if name.indexOf(query) is 0 then 1
  else if id.indexOf(query) >= 0 then 2
  else 3

search = (entries, query, limit) ->
  q = String(query or '').trim!.toLowerCase!
  cap = limit or MAX_ROWS
  return entries.slice 0, cap unless q.length
  hits = []
  for entry in entries
    haystack = "#{entry.id} #{entry.name} #{entry.kind or ''}".toLowerCase!
    continue unless haystack.indexOf(q) >= 0
    hits.push { entry: entry, rank: (rankOf entry, q) }
  hits.sort (a, b) ->
    diff = a.rank - b.rank
    if diff isnt 0 then diff else (if a.entry.name < b.entry.name then -1 else 1)
  [hit.entry for hit in hits.slice 0, cap]

label = (entry) -> entry.name or entry.id

detail = (entry) ->
  bits = [entry.id]
  bits.push "#{entry.courses} courses" if entry.courses?
  bits.push "catalog #{entry.catalogYear}" if entry.catalogYear?
  bits.join ' - '

row = (entry, onPick) ->
  el 'button', {
    class: 'school-row'
    onclick: !-> onPick entry
  }, [
    el 'span', { class: 'school-name', text: label entry }
    el 'span', { class: 'school-detail muted small', text: detail entry }
  ]

# The topbar control: type to filter, click or press Enter to go there.
typeahead = (entries, options) ->
  opts = options or {}
  list = el 'div', { class: 'school-list' }
  input = el 'input', {
    class: 'search school-search'
    type: 'search'
    placeholder: 'Search schools by name or id'
    autocomplete: 'off'
    'aria-label': 'School'
  }
  open = false

  choose = (entry) !->
    open := false
    input.value = label entry
    draw!
    opts.onPick entry

  draw = !->
    unless open
      return fill list, []
    matches = search entries, input.value
    unless matches.length
      return fill list, [el 'p', { class: 'muted small', text: 'No school matches that.' }]
    rows = [row entry, choose for entry in matches]
    rows.push el 'p', { class: 'muted small', text: "#{matches.length} of #{entries.length} schools" }
    fill list, rows

  input.addEventListener 'input', !->
    open := true
    draw!
  input.addEventListener 'focus', !->
    open := true
    input.value = ''
    draw!
  input.addEventListener 'blur', !->
    # let a click on a row land before the list closes
    window.setTimeout (!->
      open := false
      draw!
      input.value = opts.current!), 150
  input.addEventListener 'keydown', (event) !->
    if event.key is 'Enter'
      first = search(entries, input.value)[0]
      choose first if first?
    else if event.key is 'Escape'
      open := false
      input.value = opts.current!
      draw!

  input.value = opts.current!
  { el: (el 'div', { class: 'school-picker' }, [input, list]), refresh: !-> input.value = opts.current! }

# The root page: no school chosen yet, so the search is the page.
chooser = (entries, options) ->
  opts = options or {}
  list = el 'div', { class: 'school-list open' }
  input = el 'input', {
    class: 'search'
    type: 'search'
    placeholder: 'Search schools by name or id'
    autocomplete: 'off'
    'aria-label': 'Search schools'
  }
  draw = !->
    matches = search entries, input.value
    unless matches.length
      return fill list, [el 'p', { class: 'muted small', text: 'No school matches that.' }]
    fill list, [row entry, opts.onPick for entry in matches]
  input.addEventListener 'input', draw
  draw!
  parts = [
    el 'h2', { text: 'Pick your school' }
    (if opts.notice then el 'p', { class: 'muted small', text: opts.notice } else null)
    el 'p', { class: 'muted small', text: 'Each school has its own address, so a plan you are working on is one link away.' }
  ]
  if opts.recent?
    parts.push el 'div', { class: 'choices' }, [
      el 'button', {
        class: 'choice'
        text: "Back to #{label opts.recent}"
        onclick: !-> opts.onPick opts.recent
      }
    ]
  parts.push input
  parts.push list
  el 'div', { class: 'card chooser' }, parts

module.exports = { search, typeahead, chooser, label }
