# What is being dragged, held here rather than in the drag event: a
# drop target has to decide whether to accept a drag while it is still
# moving, and dataTransfer contents are not readable until the drop.
# A body class rides along so the stylesheet can light up the targets.

held = null

begin = (payload) !->
  held := payload
  document.body?.classList?.add 'dragging'

end = !->
  held := null
  document.body?.classList?.remove 'dragging'

held_ = -> held

module.exports = { begin, end, held: held_ }
