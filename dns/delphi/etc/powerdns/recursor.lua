-- Loaded via lua-config-file. Declares the RPZ feeds; policy.lua decides who
-- each one applies to.
--
-- The feed files are refreshed by the rpz-update timer, which calls
--   rec_control reload-lua-config
-- afterwards - rpzFile() reads from disk once at load and does not poll.
--
-- policyName is the handle policy.lua uses in discardPolicy(). Keep the two
-- files in step.
--
-------------------------------------------------------------------------------
-- Negative trust anchors for the internal zones.
--
-- 'home' does not exist at the root, so with dnssec.validation=validate the
-- resolver proves its non-existence and every internal lookup SERVFAILs
-- before Pythia's answer is ever considered. An NTA marks the zone Insecure
-- so the forward to Pythia is trusted as-is.
--
-- The reverse zone already works via the recursor's built-in RFC 1918
-- handling; it is listed anyway so the two zones don't behave differently if
-- that default ever changes.
-------------------------------------------------------------------------------
addNTA("home.", "internal zone, unsigned by design")
addNTA("8.168.192.in-addr.arpa.", "internal reverse zone, unsigned by design")

-- ca.peetvandesande.com is a different shape of the same problem, and a nastier
-- one: peetvandesande.com IS signed, with a valid DS at the parent and an RRSIG
-- over the public CNAME. Our internal answer is unsigned, so validation does
-- not merely fail to find a chain - it finds a good chain that says we are
-- lying, and SERVFAILs. Without this line the split-horizon override is dead.
--
-- Scoped to the single name, so www/MX and the rest of peetvandesande.com stay
-- fully validated. Keep it in step with the forward-zone in recursor.yml and
-- the zone on Pythia; all three are needed and none works alone.
addNTA("ca.peetvandesande.com.", "split-horizon to pistis, unsigned internally")

-- No defpol is set: the hagezi feeds already carry their own actions
-- (CNAME . == NXDOMAIN), and overriding them would discard that intent.
--
-- One rpzFile() per feed, driven from a table so policyName and filename
-- cannot drift apart. The names here are the handles policy.lua uses in
-- discardPolicy(); its ALL_POLICIES list must contain every one of them, or a
-- feed becomes undiscardable and applies to everyone.
--
-- zoneSizeHint is only a load-time allocation hint, but a wrong one costs a
-- rehash of the whole zone on every daily refresh. Keep them near the real
-- line counts - rpz-update logs them.
--
-- rpzFile() on a missing file is a fatal startup error, not a warning. That is
-- deliberate: a feed that silently failed to download should stop the deploy,
-- not quietly unblock half the list. deploy.sh asserts every file is present
-- before it restarts the recursor.
local FEEDS = {
  -- Default set: everyone gets these.
  {name = "ads",            hint =  400000, why = "advertising/tracking"},
  {name = "malware",        hint = 1300000, why = "malware/threat feed"},
  -- kids set.
  {name = "adult",          hint =  200000, why = "adult content"},
  {name = "gambling",       hint =  450000, why = "gambling"},
  {name = "nosafesearch",   hint =     500, why = "safe-search bypass"},
  {name = "social",         hint =    2000, why = "social media"},
  {name = "dohbypass",      hint =   35000, why = "DoH/VPN/proxy bypass"},
  -- iot set: vendor telemetry.
  {name = "native_samsung", hint =     500, why = "Samsung telemetry"},
  {name = "native_lgwebos", hint =     500, why = "LG webOS telemetry"},
  {name = "native_roku",    hint =     200, why = "Roku telemetry"},
  {name = "native_tiktok",  hint =    1000, why = "TikTok telemetry"},
}

for _, f in ipairs(FEEDS) do
  rpzFile("/var/lib/powerdns/rpz/" .. f.name .. ".rpz", {
    policyName        = f.name,
    zoneSizeHint      = f.hint,
    ignoreDuplicates  = true,
    extendedErrorCode = 15,
    extendedErrorExtra= "blocked: " .. f.why,
  })
end
