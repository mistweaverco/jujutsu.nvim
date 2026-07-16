-- Re-export popups for convenience
return {
  help = require("jujutsu.popups.help"),
  change = require("jujutsu.popups.change"),
  bookmark = require("jujutsu.popups.bookmark"),
  diff = require("jujutsu.popups.diff"),
  fetch = require("jujutsu.popups.fetch"),
  log = require("jujutsu.popups.log"),
  remote = require("jujutsu.popups.remote"),
  push = require("jujutsu.popups.push"),
  rebase = require("jujutsu.popups.rebase"),
  squash = require("jujutsu.popups.squash"),
  split = require("jujutsu.popups.split"),
  undo = require("jujutsu.popups.undo"),
  workspace = require("jujutsu.popups.workspace"),
}
