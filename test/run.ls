# Test runner: each suite registers its checks on require; summary exits
# nonzero on any failure.

helpers = require './helpers'
require './planner'
require './overrides'
require './rules'
require './scoring'
require './encoder'
helpers.summary!
