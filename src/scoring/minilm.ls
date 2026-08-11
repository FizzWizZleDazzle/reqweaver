# all-MiniLM-L6-v2 sentence encoder: a pure LiveScript forward pass over
# weights exported by tools/export-minilm.py. Runs in the browser (or
# node) with no ML runtime dependency; it only ever encodes short goal
# strings, so plain typed-array math is fast enough. Output matches the
# reference implementation (see the parity test) and is L2-normalized,
# ready for cosine against the precompiled course vectors.

# --- model loading ---------------------------------------------------------

# manifest: parsed manifest.json; buffer: ArrayBuffer of model.bin;
# vocab: array of tokens by id.
loadModel = (manifest, buffer, vocab) ->
  tensors = {}
  for name, spec of manifest.tensors
    size = 1
    for d in spec.shape
      size *= d
    tensors[name] = new Float32Array buffer, spec.offset, size
  tokenToId = {}
  for token, i in vocab
    tokenToId[token] = i
  { config: manifest.config, tensors: tensors, vocab: vocab, tokenToId: tokenToId }

# --- WordPiece tokenizer (bert-base-uncased conventions) -------------------

PUNCT = /[!-\/:-@\[-`{-~]/

basicTokens = (text) ->
  clean = text.toLowerCase!.normalize('NFD').replace(/[̀-ͯ]/g, '')
  words = clean.split /\s+/
  out = []
  for word in words when word.length
    piece = ''
    for ch in word
      if PUNCT.test ch
        out.push piece if piece.length
        out.push ch
        piece = ''
      else
        piece += ch
    out.push piece if piece.length
  out

wordpiece = (model, word) ->
  return [model.tokenToId['[UNK]']] if word.length > 100
  ids = []
  start = 0
  while start < word.length
    end = word.length
    found = null
    while end > start
      sub = word.slice start, end
      sub = '##' + sub if start > 0
      if model.tokenToId[sub]?
        found = model.tokenToId[sub]
        break
      end -= 1
    return [model.tokenToId['[UNK]']] unless found?
    ids.push found
    start = end
  ids

tokenize = (model, text) ->
  ids = [model.tokenToId['[CLS]']]
  for word in basicTokens text
    for id in wordpiece model, word
      ids.push id
  ids.push model.tokenToId['[SEP]']
  ids.slice 0, model.config.max_tokens

# --- math ------------------------------------------------------------------

# erf via Abramowitz-Stegun 7.1.26; enough precision for parity
erf = (x) ->
  sign = if x < 0 then -1 else 1
  x = Math.abs x
  t = 1 / (1 + 0.3275911 * x)
  y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-x * x)
  sign * y

gelu = (x) -> 0.5 * x * (1 + erf x / Math.sqrt(2))

# y[t] = x[t] W^T + b for HF weights of shape [out, in]
linear = (x, tokens, inDim, outDim, w, b) ->
  y = new Float32Array tokens * outDim
  for t from 0 til tokens
    xo = t * inDim
    yo = t * outDim
    for o from 0 til outDim
      s = b[o]
      wo = o * inDim
      for i from 0 til inDim
        s += x[xo + i] * w[wo + i]
      y[yo + o] = s
  y

layerNorm = (x, tokens, dim, gamma, beta, eps) ->
  for t from 0 til tokens
    base = t * dim
    mean = 0
    for i from 0 til dim
      mean += x[base + i]
    mean /= dim
    v = 0
    for i from 0 til dim
      d = x[base + i] - mean
      v += d * d
    inv = 1 / Math.sqrt(v / dim + eps)
    for i from 0 til dim
      x[base + i] = (x[base + i] - mean) * inv * gamma[i] + beta[i]
  x

addInPlace = (x, y) ->
  for i from 0 til x.length
    x[i] += y[i]
  x

# --- transformer forward ---------------------------------------------------

attention = (model, x, tokens, layer) ->
  { hidden, heads } = model.config
  headDim = hidden / heads
  T = model.tensors
  pre = "encoder.layer.#{layer}.attention."
  q = linear x, tokens, hidden, hidden, T[pre + 'self.query.weight'], T[pre + 'self.query.bias']
  k = linear x, tokens, hidden, hidden, T[pre + 'self.key.weight'], T[pre + 'self.key.bias']
  v = linear x, tokens, hidden, hidden, T[pre + 'self.value.weight'], T[pre + 'self.value.bias']
  ctx = new Float32Array tokens * hidden
  scale = 1 / Math.sqrt headDim
  scores = new Float32Array tokens
  for h from 0 til heads
    hOff = h * headDim
    for ti from 0 til tokens
      for tj from 0 til tokens
        s = 0
        for d from 0 til headDim
          s += q[ti * hidden + hOff + d] * k[tj * hidden + hOff + d]
        scores[tj] = s * scale
      max = -Infinity
      for tj from 0 til tokens
        max = scores[tj] if scores[tj] > max
      sum = 0
      for tj from 0 til tokens
        scores[tj] = Math.exp scores[tj] - max
        sum += scores[tj]
      for d from 0 til headDim
        acc = 0
        for tj from 0 til tokens
          acc += (scores[tj] / sum) * v[tj * hidden + hOff + d]
        ctx[ti * hidden + hOff + d] = acc
  out = linear ctx, tokens, hidden, hidden, T[pre + 'output.dense.weight'], T[pre + 'output.dense.bias']
  addInPlace out, x
  layerNorm out, tokens, hidden, T[pre + 'output.LayerNorm.weight'], T[pre + 'output.LayerNorm.bias'], model.config.ln_eps

feedForward = (model, x, tokens, layer) ->
  { hidden, intermediate } = model.config
  T = model.tensors
  pre = "encoder.layer.#{layer}."
  mid = linear x, tokens, hidden, intermediate, T[pre + 'intermediate.dense.weight'], T[pre + 'intermediate.dense.bias']
  for i from 0 til mid.length
    mid[i] = gelu mid[i]
  out = linear mid, tokens, intermediate, hidden, T[pre + 'output.dense.weight'], T[pre + 'output.dense.bias']
  addInPlace out, x
  layerNorm out, tokens, hidden, T[pre + 'output.LayerNorm.weight'], T[pre + 'output.LayerNorm.bias'], model.config.ln_eps

# Encode a string to a normalized 384-dim sentence vector (plain array).
encode = (model, text) ->
  { hidden, layers, ln_eps } = model.config
  ids = tokenize model, text
  tokens = ids.length
  T = model.tensors
  x = new Float32Array tokens * hidden
  for id, t in ids
    for i from 0 til hidden
      x[t * hidden + i] =
        T['embeddings.word_embeddings.weight'][id * hidden + i] +
        T['embeddings.position_embeddings.weight'][t * hidden + i] +
        T['embeddings.token_type_embeddings.weight'][i]
  layerNorm x, tokens, hidden, T['embeddings.LayerNorm.weight'], T['embeddings.LayerNorm.bias'], ln_eps
  for layer from 0 til layers
    x = attention model, x, tokens, layer
    x = feedForward model, x, tokens, layer
  # mean pooling over tokens, then L2 normalize
  pooled = []
  for i from 0 til hidden
    s = 0
    for t from 0 til tokens
      s += x[t * hidden + i]
    pooled.push s / tokens
  norm = 0
  for v in pooled
    norm += v * v
  norm = Math.sqrt norm
  [v / norm for v in pooled]

module.exports = { loadModel, encode, tokenize }
