local async = require("jujutsu.async")
local config = require("jujutsu.config")
local finder = require("jujutsu.finder")

local M = {}

---@class ForgeStoredCreds
---@field user? string
---@field token string

---In-memory overrides (take priority over config/env/disk for the session).
---@type table<string, ForgeStoredCreds>
local memory = {}

---@return string
local function store_path()
  local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "jujutsu")
  vim.fn.mkdir(dir, "p")
  return vim.fs.joinpath(dir, "credentials.json")
end

---@return table
local function load_store()
  local path = store_path()
  local f = io.open(path, "r")
  if not f then return { bitbucket = {}, forgejo = {} } end
  local raw = f:read("*a")
  f:close()
  if not raw or raw == "" then return { bitbucket = {}, forgejo = {} } end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return { bitbucket = {}, forgejo = {} } end
  decoded.bitbucket = type(decoded.bitbucket) == "table" and decoded.bitbucket or {}
  decoded.forgejo = type(decoded.forgejo) == "table" and decoded.forgejo or {}
  return decoded
end

---@param store table
local function save_store(store)
  local path = store_path()
  local f = io.open(path, "w")
  if not f then return false end
  f:write(vim.json.encode(store))
  f:close()
  -- Restrict permissions when possible (owner read/write only)
  pcall(vim.uv.fs_chmod, path, 384) -- 0600
  return true
end

---@param remote ForgeRemote
---@return string|nil
function M.storage_key(remote)
  if not remote then return nil end
  if remote.provider == "bitbucket" then return remote.owner end
  if remote.provider == "forgejo" then return remote.host end
  return nil
end

---@param remote ForgeRemote
---@return string|nil
local function memory_key(remote)
  local key = M.storage_key(remote)
  if not key then return nil end
  return remote.provider .. ":" .. key
end

---@param remote ForgeRemote
---@param creds ForgeStoredCreds
function M.set(remote, creds)
  local key = M.storage_key(remote)
  if not key or not remote then return false end
  local mk = memory_key(remote)
  if mk then memory[mk] = { user = creds.user, token = creds.token } end
  local store = load_store()
  local bucket = remote.provider
  if bucket ~= "bitbucket" and bucket ~= "forgejo" then return false end
  store[bucket][key] = { user = creds.user, token = creds.token }
  return save_store(store)
end

---@param remote ForgeRemote
function M.delete(remote)
  local key = M.storage_key(remote)
  if not key or not remote then return false end
  local mk = memory_key(remote)
  if mk then memory[mk] = nil end
  local store = load_store()
  local bucket = remote.provider
  if bucket ~= "bitbucket" and bucket ~= "forgejo" then return false end
  store[bucket][key] = nil
  return save_store(store)
end

---@param remote ForgeRemote
---@return ForgeStoredCreds|nil
function M.get_stored(remote)
  local key = M.storage_key(remote)
  if not key or not remote then return nil end
  local store = load_store()
  local bucket = remote.provider
  if bucket ~= "bitbucket" and bucket ~= "forgejo" then return nil end
  local entry = store[bucket][key]
  if type(entry) ~= "table" or not entry.token or entry.token == "" then return nil end
  if remote.provider == "bitbucket" and (not entry.user or entry.user == "") then return nil end
  return entry
end

---Resolve credentials without prompting. Priority: memory → disk → config → env.
---@param remote ForgeRemote
---@return ForgeStoredCreds|nil, string|nil source
function M.resolve(remote)
  if not remote then return nil, nil end

  local mk = memory_key(remote)
  if mk and memory[mk] and memory[mk].token and memory[mk].token ~= "" then
    if remote.provider ~= "bitbucket" or (memory[mk].user and memory[mk].user ~= "") then
      return memory[mk], "memory"
    end
  end

  local stored = M.get_stored(remote)
  if stored then return stored, "disk" end

  if remote.provider == "bitbucket" then
    local bb = (config.values.forge and config.values.forge.bitbucket) or {}
    local user = bb.user or vim.env.BITBUCKET_USER
    local token = bb.token or vim.env.BITBUCKET_TOKEN
    if user and user ~= "" and token and token ~= "" then
      local source = (bb.user or bb.token) and "config" or "env"
      return { user = user, token = token }, source
    end
    return nil, nil
  end

  if remote.provider == "forgejo" then
    local fj = (config.values.forge and config.values.forge.forgejo) or {}
    local token = fj.token or vim.env.FORGEJO_TOKEN or vim.env.CODEBERG_TOKEN
    if token and token ~= "" then
      local source = fj.token and "config" or "env"
      return { token = token }, source
    end
    return nil, nil
  end

  return nil, nil
end

---@param remote ForgeRemote
---@return boolean
function M.has(remote)
  local creds = M.resolve(remote)
  return creds ~= nil
end

---@param remote ForgeRemote
---@param defaults? ForgeStoredCreds
---@param cb fun(creds: ForgeStoredCreds|nil)
function M.prompt(remote, defaults, cb)
  defaults = defaults or {}
  vim.schedule(function()
    async.void(function()
      local creds = nil
      if remote.provider == "bitbucket" then
        local workspace = remote.owner or "workspace"
        local user = finder.input({
          prompt = string.format("Bitbucket Atlassian email (%s): ", workspace),
          default = defaults.user or "",
        })
        if not user or user == "" then
          cb(nil)
          return
        end
        local token = finder.input({
          prompt = string.format("Bitbucket API token with write:pullrequest (%s): ", workspace),
          default = defaults.token or "",
        })
        if not token or token == "" then
          cb(nil)
          return
        end
        creds = { user = user, token = token }
      elseif remote.provider == "forgejo" then
        local host = remote.host or "forgejo"
        local token = finder.input({
          prompt = string.format("Forgejo/Codeberg token (%s): ", host),
          default = defaults.token or "",
        })
        if not token or token == "" then
          cb(nil)
          return
        end
        creds = { token = token }
      end
      cb(creds)
    end)
  end)
end

---Ensure credentials exist, prompting and persisting when missing.
---@param remote ForgeRemote
---@param cb fun(ok: boolean)
function M.ensure(remote, cb)
  if remote.provider ~= "bitbucket" and remote.provider ~= "forgejo" then
    cb(true)
    return
  end
  if M.has(remote) then
    cb(true)
    return
  end
  local label = remote.provider == "bitbucket" and ("Bitbucket workspace " .. (remote.owner or "?"))
    or ("Forgejo host " .. (remote.host or "?"))
  require("jujutsu.notify").info("No stored credentials for " .. label)
  M.prompt(remote, nil, function(creds)
    if not creds then
      require("jujutsu.notify").warn("Credential entry cancelled")
      cb(false)
      return
    end
    if not M.set(remote, creds) then
      require("jujutsu.notify").error("Failed to save credentials")
      cb(false)
      return
    end
    require("jujutsu.notify").info("Credentials saved under stdpath('data')/jujutsu/credentials.json")
    cb(true)
  end)
end

---Ask whether to update or delete credentials after an auth failure.
---@param remote ForgeRemote
---@param cb fun(action: "updated"|"deleted"|"cancelled")
function M.handle_invalid(remote, cb)
  if remote.provider ~= "bitbucket" and remote.provider ~= "forgejo" then
    cb("cancelled")
    return
  end

  local _, source = M.resolve(remote)
  local label = remote.provider == "bitbucket" and ("workspace " .. (remote.owner or "?"))
    or ("host " .. (remote.host or "?"))

  local choices = {
    { id = "update", text = "Supply new credentials" },
  }
  if source == "disk" or source == "memory" then
    table.insert(choices, { id = "delete", text = "Delete stored credentials" })
  end
  table.insert(choices, { id = "cancel", text = "Cancel" })

  local prompt = string.format(
    "Auth/scope problem for %s (%s). "
      .. "If scopes are missing, create a new API token with the required permissions "
      .. "(re-entering the same token will not help). Update credentials?",
    label,
    source or "unknown"
  )

  vim.schedule(function()
    async.void(function()
      local entries = {}
      local id_by_text = {}
      for _, choice in ipairs(choices) do
        table.insert(entries, choice.text)
        id_by_text[choice.text] = choice.id
      end
      local selected = finder.pick({ prompt = prompt, entries = entries })
      if not selected then
        cb("cancelled")
        return
      end
      local action = id_by_text[tostring(selected)]
      if not action or action == "cancel" then
        cb("cancelled")
        return
      end
      if action == "delete" then
        M.delete(remote)
        require("jujutsu.notify").info("Stored credentials deleted")
        cb("deleted")
        return
      end
      local current = select(1, M.resolve(remote)) or {}
      M.prompt(remote, current, function(creds)
        if not creds then
          cb("cancelled")
          return
        end
        if not M.set(remote, creds) then
          require("jujutsu.notify").error("Failed to save credentials")
          cb("cancelled")
          return
        end
        require("jujutsu.notify").info("Credentials updated")
        cb("updated")
      end)
    end)
  end)
end

---@param err string|nil
---@param status integer|nil
---@return boolean
function M.is_auth_error(err, status) return require("jujutsu.forge.http").is_auth_error(err, status) end

---@param err string|nil
---@param status integer|nil
---@return boolean
function M.is_scope_error(err, status) return require("jujutsu.forge.http").is_scope_error(err, status) end

return M
