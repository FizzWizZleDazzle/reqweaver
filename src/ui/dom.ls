# Minimal DOM helpers. The app builds elements directly; no framework, no
# virtual DOM. Components return { el, refresh } so a state change updates
# the parts that changed and leaves transient state (filter text, focus,
# scroll position) alone.

PROPS = <[ checked disabled selected value open ]>

append = (node, kids) !->
  return unless kids?
  list = if Array.isArray kids then kids else [kids]
  for kid in list
    continue unless kid?
    continue if kid is false
    if typeof kid is 'string' or typeof kid is 'number'
      node.appendChild document.createTextNode String kid
    else
      node.appendChild kid

el = (tag, attrs, kids) ->
  node = document.createElement tag
  for key, value of (attrs or {})
    continue unless value?
    if key is 'text'
      node.textContent = value
    else if key is 'class'
      node.className = value
    else if key.slice(0, 2) is 'on'
      node.addEventListener key.slice(2), value
    else if key in PROPS
      node[key] = value
    else
      node.setAttribute key, value
  append node, kids
  node

clear = (node) !->
  node.textContent = '' if node?

# Replace a node's children in one step.
fill = (node, kids) !->
  clear node
  append node, kids

module.exports = { el, clear, fill, append }
