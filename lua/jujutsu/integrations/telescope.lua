-- Thin wrappers kept for explicit require paths; finder.lua owns detection.
return {
  available = function() return pcall(require, "telescope") end,
}
