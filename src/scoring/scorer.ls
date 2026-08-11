# Soft scorer: features in, scalar out. The YAML weights file is the whole
# model and the forward pass is a dot product, so tuning the product's
# taste means editing data, not code. The scorer only orders plans that
# already passed every symbolic check; it can never affect feasibility.

{ extract } = require './features'

score = (weights, features) ->
  total = 0
  for name, weight of (weights.weights or {})
    total += weight * (features[name] or 0)
  total

# Rank symbolic survivors best-first; deterministic via signature tiebreak.
rank = (model, plans, weights) ->
  scored = []
  for state in plans
    features = extract model, state
    scored.push { st: state, soft: score(weights, features), features: features }
  scored.sort (a, b) ->
    diff = b.soft - a.soft
    if diff isnt 0 then diff else (if a.st.sig < b.st.sig then -1 else 1)
  scored

module.exports = { score, rank }
