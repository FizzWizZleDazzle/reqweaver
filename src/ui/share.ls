# Saving a plan to the API and sharing it. There are no accounts: a save
# returns a plan id, which is the link anyone can read, and a write token
# this browser keeps so it alone can update or delete that plan. The list
# of saves lives in localStorage, so clearing the browser loses the
# ability to change a saved plan, and the plan itself stays readable.

{ el, fill } = require './dom'
state = require './state'
api = require './api'

SHARE_CAVEAT = 'Anyone with the link can read the plan, including the courses you have completed. There is no password on it. Share it with the people you mean to.'

stamp = (value) ->
  return '' unless value?
  try
    (new Date value).toISOString!.slice 0, 10
  catch e
    ''

create = (ctx) ->
  root = el 'div', { class: 'card share' }
  message = el 'p', { class: 'muted small' }
  busy = false

  # What a saved plan is: the profile that produced it, the assignments
  # it landed on, and the specsheet it was built against, so a reader
  # sees the same plan without re-solving it.
  payloadFor = (name) ->
    shown = ctx.snapshot!
    return null unless shown?
    {
      v: 1
      savedAt: (new Date!).toISOString!
      name: name
      specsheetPins: [{ id: ctx.entry.id, catalogYear: ctx.school.catalog_year, path: ctx.entry.path }]
      profile: state.profile!
      objective: shown.objective
      assignments: shown.terms
      coverage: shown.coverage
      banked: shown.banked
      gradRemaining: shown.gradRemaining
      scores: { symbolic: shown.objectiveScore, soft: shown.soft }
    }

  say = (text) !-> message.textContent = text

  failure = (result, what) ->
    return "#{what}: the API is not reachable from here." if result.status is 0
    detail = result.body?.error or "status #{result.status}"
    "#{what}: #{detail}."

  copy = (text) !->
    board = window.navigator?.clipboard
    if board?.writeText?
      board.writeText(text).then (!-> say 'Link copied.'), (!-> say "Copy this link: #{text}")
    else
      say "Copy this link: #{text}"

  saveNow = !->
    return if busy
    payload = payloadFor nameInput.value.trim! or defaultName!
    unless payload?
      return say 'Run the planner first; there is no plan to save yet.'
    busy := true
    say 'Saving...'
    api.savePlan(ctx.config, payload).then (result) !->
      busy := false
      unless result.ok and result.body?.planId?
        return say failure result, 'Could not save'
      state.rememberSave {
        planId: result.body.planId
        writeToken: result.body.writeToken
        name: payload.name
        schoolId: ctx.entry.id
        savedAt: payload.savedAt
        updatedAt: payload.savedAt
      }
      say 'Saved. The link below is the plan.'
      render!

  updateSave = (record) !->
    return if busy
    payload = payloadFor record.name
    unless payload?
      return say 'Run the planner first; there is no plan to save yet.'
    busy := true
    say "Updating #{record.name}..."
    api.updatePlan(ctx.config, record.planId, record.writeToken, payload).then (result) !->
      busy := false
      unless result.ok
        return say failure result, 'Could not update'
      state.touchSave record.planId, { updatedAt: payload.savedAt }
      say "Updated #{record.name}."
      render!

  deleteSave = (record) !->
    return if busy
    return unless window.confirm "Delete #{record.name}? The link stops working for everyone."
    busy := true
    api.deletePlan(ctx.config, record.planId, record.writeToken).then (result) !->
      busy := false
      # a plan already gone from the API is still dropped from the list
      unless result.ok or result.status is 404
        return say failure result, 'Could not delete'
      state.forgetSave record.planId
      say "Deleted #{record.name}."
      render!

  defaultName = -> "#{ctx.school.name} plan"

  nameInput = el 'input', {
    class: 'input save-name'
    type: 'text'
    placeholder: 'Name this plan'
    'aria-label': 'Plan name'
  }

  savedRow = (record) ->
    link = api.shareUrl record.planId
    el 'div', { class: 'save-row' }, [
      el 'div', { class: 'save-head' }, [
        el 'span', { class: 'save-name-text', text: record.name }
        el 'span', { class: 'muted small', text: "saved #{stamp record.savedAt}#{if record.updatedAt and record.updatedAt isnt record.savedAt then ", updated #{stamp record.updatedAt}" else ''}" }
      ]
      el 'div', { class: 'save-link' }, [
        el 'a', { href: link, text: link }
      ]
      el 'div', { class: 'choices' }, [
        el 'button', { class: 'choice', text: 'Copy link', onclick: !-> copy link }
        el 'button', { class: 'choice', text: 'Update to this plan', title: 'Replace what the link shows with the plan on screen', onclick: !-> updateSave record }
        el 'button', { class: 'ghost', text: 'Delete', onclick: !-> deleteSave record }
      ]
    ]

  render = !->
    records = [record for record in state.saves! when record.schoolId is ctx.entry.id]
    parts = [
      el 'h2', { text: 'Save and share' }
      el 'p', { class: 'muted small', text: 'A save stores the plan on the reqweaver API and gives you a link to it. No account, no password: the link is the plan.' }
      el 'div', { class: 'save-controls' }, [
        nameInput
        el 'button', { class: 'primary', text: 'Save this plan', onclick: saveNow }
      ]
      message
    ]
    if records.length
      parts.push el 'h3', { text: 'Saved from this browser' }
      parts.push el 'p', { class: 'muted small', text: SHARE_CAVEAT }
      for record in records
        parts.push savedRow record
    fill root, parts

  render!
  { el: root, refresh: render }

module.exports = { create, SHARE_CAVEAT }
