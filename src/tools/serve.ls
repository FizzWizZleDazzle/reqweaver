# Static file server for local testing, with no dependencies beyond node.
# Run: node lib/tools/serve.js [port] [--watch]
# --watch rebuilds the site when sources change and reloads open tabs:
# served pages get a script listening on /__reload (server-sent events),
# and a successful rebuild pings every listener.

http = require 'http'
fs = require 'fs'
path = require 'path'
{ spawn } = require 'child_process'

BASE = path.join __dirname, '..', '..'
ROOT = path.join BASE, 'public'

watching = process.argv.indexOf('--watch') >= 0
portArg = null
for arg in process.argv.slice 2
  portArg = arg unless arg is '--watch'
port = parseInt(portArg or '8080', 10)

TYPES =
  '.html': 'text/html; charset=utf-8'
  '.css': 'text/css; charset=utf-8'
  '.js': 'text/javascript; charset=utf-8'
  '.json': 'application/json; charset=utf-8'
  '.yaml': 'text/plain; charset=utf-8'
  '.svg': 'image/svg+xml'

RELOAD_TAG = '<script>new EventSource("/__reload").onmessage=function(){location.reload()}</script>'

# Local stand-in for the deployed Worker's POST /encode: the pure
# LiveScript encoder over the data/encoder export (npm run
# export-model), so a typed goal steers plans on localhost too. Lazy;
# absent export answers 503 and the app degrades the same way it does
# offline.
encoderState = null
loadEncoder = ->
  return encoderState if encoderState?
  dir = path.join BASE, 'data', 'encoder'
  return null unless fs.existsSync path.join(dir, 'manifest.json')
  mod = require path.join(BASE, 'lib', 'scoring', 'encoder.js')
  manifest = JSON.parse fs.readFileSync path.join(dir, 'manifest.json'), 'utf8'
  vocab = JSON.parse fs.readFileSync path.join(dir, 'vocab.json'), 'utf8'
  buf = fs.readFileSync path.join(dir, 'model.bin')
  ab = buf.buffer.slice buf.byteOffset, buf.byteOffset + buf.byteLength
  encoderState := {
    mod: mod
    model: mod.loadModel manifest, ab, vocab
    name: manifest.model or 'bge-small-en-v1.5'
  }
  encoderState

handleEncode = (request, response) !->
  enc = loadEncoder!
  unless enc?
    return send response, 503, 'application/json', JSON.stringify { error: 'no local encoder export; run npm run export-model' }
  chunks = []
  request.on 'data', (chunk) !-> chunks.push chunk
  request.on 'end', !->
    try
      text = String(JSON.parse(Buffer.concat(chunks).toString('utf8')).text or '')
      vector = enc.mod.encode enc.model, text
      send response, 200, 'application/json', JSON.stringify { model: enc.name, vector: Array.from(vector) }
    catch e
      send response, 400, 'application/json', JSON.stringify { error: String(e.message or e) }

clients = []

broadcast = !->
  for c in clients
    c.write 'data: reload\n\n'

send = (response, code, type, body) !->
  response.writeHead code, { 'content-type': type }
  response.end body

sendFile = (response, target, fallback) !->
  fs.readFile target, (error, body) !->
    if error?
      return fallback!
    type = TYPES[path.extname target] or 'application/octet-stream'
    if watching and (path.extname target) is '.html'
      body = Buffer.concat [body, Buffer.from RELOAD_TAG]
    send response, 200, type, body

# Client routes (/us/md/mcps/wchs, /s/<code>) are paths the app reads,
# not files, so anything without a file behind it gets the page. This
# matches what the deployed Worker does.
handle = (request, response) !->
  requested = decodeURIComponent (request.url.split '?')[0]
  if requested is '/encode' and request.method is 'POST'
    return handleEncode request, response
  if watching and requested is '/__reload'
    response.writeHead 200, {
      'content-type': 'text/event-stream'
      'cache-control': 'no-cache'
    }
    response.write ': connected\n\n'
    clients.push response
    request.on 'close', !->
      i = clients.indexOf response
      clients.splice i, 1 if i >= 0
    return
  requested = '/index.html' if requested is '/'
  target = path.join ROOT, requested
  # Never serve outside public/.
  unless target.indexOf(ROOT) is 0
    return send response, 403, 'text/plain', 'forbidden'
  sendFile response, target, !->
    if path.extname requested
      return send response, 404, 'text/plain', "not found: #{requested}"
    sendFile response, (path.join ROOT, 'index.html'), !->
      send response, 404, 'text/plain', 'not found: index.html; run npm run build:web'

# --- watch mode ------------------------------------------------------------

# Everything the site is built from; lib/ and public/ are outputs and
# stay out so a rebuild does not retrigger itself.
WATCH = ['src', 'specs', 'registry', 'weights', 'siteconfig.yaml']

# One string describing every watched file's mtime and size. Polling a
# tree this small is cheap and avoids fs.watch platform quirks.
signature = ->
  parts = []
  walk = (p) !->
    stat = null
    try stat = fs.statSync p
    return unless stat?
    if stat.isDirectory!
      for name in fs.readdirSync(p).sort!
        walk path.join(p, name)
    else
      parts.push "#{p}:#{stat.mtimeMs}:#{stat.size}"
  for entry in WATCH
    walk path.join(BASE, entry)
  parts.join '\n'

building = false
dirty = false
lastSig = null
pendingSig = null

rebuild = !->
  building := true
  console.log 'change detected; rebuilding...'
  child = spawn 'npm', ['run', 'build:web'], { cwd: BASE, stdio: 'inherit' }
  child.on 'exit', (code) !->
    building := false
    if code is 0
      console.log 'rebuilt; reloading tabs'
      broadcast!
    else
      console.log "build failed (exit #{code}); fix and save again"
    if dirty
      dirty := false
      rebuild!

# A change only triggers a rebuild once the tree has been still for a
# full poll interval, so a burst of saves builds once. A change landing
# mid-build marks dirty and rebuilds again after.
pollChanges = !->
  sig = signature!
  return if sig is lastSig
  if sig is pendingSig
    lastSig := sig
    pendingSig := null
    if building then dirty := true else rebuild!
  else
    pendingSig := sig

http.createServer(handle).listen port, !->
  mode = if watching then ' (watch: rebuild + reload on save)' else ''
  console.log "reqweaver on http://localhost:#{port} (serving #{ROOT})#{mode}"

if watching
  lastSig = signature!
  setInterval pollChanges, 400
