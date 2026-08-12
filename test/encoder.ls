# Parity: the LiveScript sentence encoder must reproduce the reference
# vectors. Runs only when the model export exists (npm run export-model).

fs = require 'fs'
path = require 'path'
assert = require 'assert'
{ ROOT, check } = require './helpers'
{ cosine } = require '../engine/search'

encoderDir = path.join ROOT, 'data', 'encoder'
if fs.existsSync path.join(encoderDir, 'manifest.json')
  check 'LiveScript sentence encoder matches the reference vectors', ->
    encoder = require '../scoring/encoder'
    manifest = JSON.parse fs.readFileSync path.join(encoderDir, 'manifest.json'), 'utf8'
    vocab = JSON.parse fs.readFileSync path.join(encoderDir, 'vocab.json'), 'utf8'
    refs = JSON.parse fs.readFileSync path.join(encoderDir, 'refs.json'), 'utf8'
    buf = fs.readFileSync path.join(encoderDir, 'model.bin')
    enc = encoder.loadModel manifest, buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength), vocab
    for sentence, ref of refs
      sim = cosine (encoder.encode enc, sentence), ref
      assert sim > 0.999, "cosine to reference only #{sim.toFixed 5} for: #{sentence}"
else
  console.log 'skip encoder parity (no data/encoder export; run npm run export-model)'
