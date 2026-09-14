-- Loaded via lua-dns-script.
--
-- One recursor, two policies. Every RPZ in recursor.lua is loaded for every
-- query; prerpz() then throws away the ones that shouldn't apply to *this*
-- client before the policy engine runs.
--
-- The recursor has no native "apply this RPZ only to tagged queries" switch -
-- rpzFile()'s `tags` option only labels protobuf output, it does not gate
-- matching - so discardPolicy() in prerpz is the supported way to do this.

local KIDS_TLV = 224          -- must match SetProxyProtocolValuesAction on Themis
local KIDS_ONLY = {"adult", "social"}

-- True when Themis stamped this query as coming from a kids device.
local function isKids(dq)
  local values = dq:getProxyProtocolValues()
  if not values then return false end
  for _, v in ipairs(values) do
    if v:getType() == KIDS_TLV and v:getContent() == "kids" then
      return true
    end
  end
  return false
end

function prerpz(dq)
  if not isKids(dq) then
    for _, policy in ipairs(KIDS_ONLY) do
      dq:discardPolicy(policy)
    end
  end
  -- false == carry on with normal processing; we've only adjusted which
  -- policies are in play, not the answer.
  return false
end
