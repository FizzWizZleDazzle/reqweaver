# Folds the worker bundle into the page bundle so the app ships as one
# script: worker.js becomes a string on window.__WORKER_SRC__ that the
# solver turns into a blob URL, and the separate file stops shipping.
# Run after both esbuild outputs exist (npm run build:web does).

fs = require 'fs'
path = require 'path'

OUT = path.join __dirname, '..', '..', 'public'

main = !->
  appPath = path.join OUT, 'app.js'
  workerPath = path.join OUT, 'worker.js'
  unless fs.existsSync(appPath) and fs.existsSync(workerPath)
    console.error 'onefile: missing app.js or worker.js; run the bundles first'
    process.exit 1
  worker = fs.readFileSync workerPath, 'utf8'
  app = fs.readFileSync appPath, 'utf8'
  fs.writeFileSync appPath, "window.__WORKER_SRC__=#{JSON.stringify worker};\n" + app
  fs.unlinkSync workerPath
  size = Math.round fs.statSync(appPath).size / 1024
  console.log "onefile: worker inlined; app.js is #{size} KB and the only script"

main!
