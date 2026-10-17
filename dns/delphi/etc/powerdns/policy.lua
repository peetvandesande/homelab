-- Loaded via lua-dns-script.
--
-- One recursor, several policies. Every RPZ in recursor.lua is loaded for every
-- query; prerpz() then throws away the ones that shouldn't apply to *this*
-- client before the policy engine runs.
--
-- The recursor has no native "apply this RPZ only to tagged queries" switch -
-- rpzFile()'s `tags` option only labels protobuf output, it does not gate
-- matching - so discardPolicy() in prerpz is the supported way to do this. Note
-- the polarity: the default is the lightest policy set and everything else is
-- opt-in, so a bug here under-blocks rather than breaking the LAN.

local POLICY_TLV = 224        -- must match SetProxyProtocolValuesAction on Themis

-- Every policyName declared in recursor.lua. A feed missing from this list can
-- never be discarded, so it would silently apply to everyone.
local ALL_POLICIES = {
  "ads", "malware", "doh",
  "adult", "gambling", "nosafesearch", "social", "dohbypass",
  "native_samsung", "native_lgwebos", "native_roku", "native_tiktok",
}

-- Keys are the TLV values Themis stamps, and the policy set names in
-- themis/etc/dnsdist/client-policies.conf. "" is the default set: no tag.
local POLICY_SETS = {
  [""]   = { ads = true, malware = true, doh = true },
  kids   = { ads = true, malware = true, doh = true, adult = true,
             gambling = true, nosafesearch = true, social = true,
             dohbypass = true },
  iot    = { ads = true, malware = true, doh = true, native_samsung = true,
             native_lgwebos = true, native_roku = true, native_tiktok = true },
}

-------------------------------------------------------------------------------
-- Allowlists
--
-- Done here rather than as a passthru RPZ zone on purpose. RPZ precedence
-- across zones is by resolution stage, not load order, since recursor 4.4, and
-- a passthru match in one zone is not documented to stop another zone
-- applying. discardPolicy() is unambiguous, and it is the mechanism this file
-- already relies on.
--
-- Matching is per label suffix, so an entry covers a name and everything under
-- it. A handful of hash lookups per query; no measurable cost.
-------------------------------------------------------------------------------
local function loadList(path)
  local set, n = {}, 0
  local fh = io.open(path, "r")
  if not fh then return set, 0 end
  for line in fh:lines() do
    local name = line:gsub("#.*", ""):gsub("%s", ""):lower()
    if #name > 0 then
      if name:sub(-1) ~= "." then name = name .. "." end
      set[name], n = true, n + 1
    end
  end
  fh:close()
  return set, n
end

local ALLOW         = loadList("/etc/powerdns/allowlist.conf")
local ALLOW_MALWARE = loadList("/etc/powerdns/allowlist-malware.conf")

local function listed(set, qname)
  if next(set) == nil then return false end
  local name = qname:toString():lower()
  while #name > 1 do
    if set[name] then return true end
    name = name:gsub("^[^.]*%.", "", 1)
  end
  return false
end

-- Which policy set Themis assigned this query. Unknown or absent tag means the
-- default set, so a stale tag can never widen what a client is allowed.
local function policySetOf(dq)
  local values = dq:getProxyProtocolValues()
  if not values then return "" end
  for _, v in ipairs(values) do
    if v:getType() == POLICY_TLV then
      local name = v:getContent()
      if POLICY_SETS[name] then return name end
    end
  end
  return ""
end

function prerpz(dq)
  local set      = POLICY_SETS[policySetOf(dq)]
  local allowAll = listed(ALLOW_MALWARE, dq.qname)
  local allow    = allowAll or listed(ALLOW, dq.qname)

  for _, policy in ipairs(ALL_POLICIES) do
    if not set[policy] then
      -- Not part of this client's policy set.
      dq:discardPolicy(policy)
    elseif allow and (policy ~= "malware" or allowAll) then
      -- Allowlisted. The plain allowlist deliberately cannot punch through the
      -- malware feed; allowlist-malware.conf is the one that can.
      dq:discardPolicy(policy)
    end
  end

  -- false == carry on with normal processing; we've only adjusted which
  -- policies are in play, not the answer.
  return false
end
