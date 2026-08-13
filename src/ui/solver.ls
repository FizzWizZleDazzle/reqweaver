# Worker client. The worker outlives a solve, so anything it loaded once
# (the specsheet, the course vectors, the sentence encoder) is still there
# for the next run. One solve at a time: starting a run while one is in
# flight replaces the worker, which is also how cancelling works, since a
# beam search in progress does not check for messages.

# The build inlines the worker bundle into the page script as a string,
# so the whole app ships as one file; the blob URL is created once, and
# the separate-file path remains for un-inlined builds (the dev server).
workerUrl = ->
  src = window.__WORKER_SRC__
  return 'worker.js' unless src
  window.__WORKER_URL__ ?= URL.createObjectURL new Blob [src], { type: 'text/javascript' }
  window.__WORKER_URL__

create = (handlers) ->
  worker = null
  current = null
  finished = null
  counter = 0

  # Hints arrive after the plans, so they are matched against the solve
  # that just finished as well as the one in flight.
  receive = (event) !->
    message = event.data
    return unless message?
    if message.type is 'hints'
      return unless message.id is finished or message.id is current
      return handlers.hints? message
    return if message.id? and message.id isnt current
    switch message.type
    | 'status' => handlers.status? message
    | 'done'   =>
      finished := current
      current := null
      handlers.done? message
    | 'error'  =>
      current := null
      handlers.error? message

  broke = (event) !->
    current := null
    handlers.error? { message: event.message or 'the planner worker failed to start' }

  spawn = ->
    made = new Worker workerUrl!
    made.addEventListener 'message', receive
    made.addEventListener 'error', broke
    made

  stop = !->
    if worker?
      worker.terminate!
      worker := null
    current := null
    finished := null

  run = (job) !->
    stop! if current?
    worker := spawn! unless worker?
    counter += 1
    current := counter
    worker.postMessage ({ type: 'solve', id: counter, base: document.baseURI } <<< job)

  cancel = !->
    return unless current?
    stop!
    handlers.cancelled?!

  { run, cancel, running: -> current? }

# The rule-check client, on its own worker so a beam search in flight
# never delays a grid check. A validate is quick and never cancelled;
# the worker lives for the whole page, and only the newest report is
# delivered.
validator = (handlers) ->
  worker = null
  counter = 0

  receive = (event) !->
    message = event.data
    return unless message? and message.id is counter
    switch message.type
    | 'validated' => handlers.report? message
    | 'error'     => handlers.error? message

  spawn = ->
    made = new Worker workerUrl!
    made.addEventListener 'message', receive
    made.addEventListener 'error', (event) !->
      handlers.error? { message: event.message or 'the rule-check worker failed to start' }
    made

  run = (job) !->
    worker := spawn! unless worker?
    counter += 1
    worker.postMessage ({ type: 'validate', id: counter, base: document.baseURI } <<< job)

  stop = !->
    worker?.terminate!
    worker := null

  { run, stop }

module.exports = { create, validator }
