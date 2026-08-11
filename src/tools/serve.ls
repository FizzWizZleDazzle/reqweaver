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

handle = (request, response) !->
  requested = decodeURIComponent (request.url.split '?')[0]
  requested = '/index.html' if requested is '/'
  target = path.join ROOT, requested
  # Never serve outside public/.
  unless target.indexOf(ROOT) is 0
    return send response, 403, 'text/plain', 'forbidden'
  fs.readFile target, (error, body) !->
    if error?
      return send response, 404, 'text/plain', "not found: #{requested}"
    type = TYPES[path.extname target] or 'application/octet-stream'
    send response, 200, type, body

port = parseInt(process.argv[2] or '8080', 10)
http.createServer(handle).listen port, !->
  console.log "reqweaver on http://localhost:#{port} (serving #{ROOT})"
