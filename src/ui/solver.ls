# Worker client. One solve at a time: starting a new run replaces the
# worker, which is also how cancelling works, since a beam search in
# progress does not check for messages.

create = (handlers) ->
  worker = null
  current = null
  counter = 0

  stop = !->
    if worker?
      worker.terminate!
      worker := null
    current := null

  run = (job) !->
    stop!
    counter += 1
    current := counter
    id = counter
    worker := new Worker 'worker.js'
    worker.addEventListener 'message', (event) !->
      message = event.data
      return unless message?
      return if message.id? and message.id isnt id
      switch message.type
      | 'status' => handlers.status? message
      | 'done'   =>
        current := null
        handlers.done? message
      | 'error'  =>
        current := null
        handlers.error? message
    worker.addEventListener 'error', (event) !->
      current := null
      handlers.error? { message: event.message or 'the planner worker failed to start' }
    worker.postMessage ({ type: 'solve', id: id } <<< job)

  cancel = !->
    return unless current?
    stop!
    handlers.cancelled?!

  { run, cancel, running: -> current? }

module.exports = { create }
