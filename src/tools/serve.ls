# Static file server for local testing, with no dependencies beyond node.
# Run: node lib/tools/serve.js [port]   (npm run serve does it for you)

http = require 'http'
fs = require 'fs'
path = require 'path'

ROOT = path.join __dirname, '..', '..', 'public'

TYPES =
  '.html': 'text/html; charset=utf-8'
  '.css': 'text/css; charset=utf-8'
  '.js': 'text/javascript; charset=utf-8'
  '.json': 'application/json; charset=utf-8'
  '.yaml': 'text/plain; charset=utf-8'
  '.svg': 'image/svg+xml'

send = (response, code, type, body) !->
  response.writeHead code, { 'content-type': type }
  response.end body

sendFile = (response, target, fallback) !->
  fs.readFile target, (error, body) !->
    if error?
      return fallback!
    type = TYPES[path.extname target] or 'application/octet-stream'
    send response, 200, type, body

# Client routes (/us/md/mcps/wchs, /s/<code>) are paths the app reads,
# not files, so anything without a file behind it gets the page. This
# matches what the deployed Worker does.
handle = (request, response) !->
  requested = decodeURIComponent (request.url.split '?')[0]
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

port = parseInt(process.argv[2] or '8080', 10)
http.createServer(handle).listen port, !->
  console.log "reqweaver on http://localhost:#{port} (serving #{ROOT})"
