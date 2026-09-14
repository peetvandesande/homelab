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
addNTA("1.168.192.in-addr.arpa.", "internal reverse zone, unsigned by design")

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

-- Applies to everyone.
rpzFile("/var/lib/powerdns/rpz/malware.rpz", {
  policyName        = "malware",
  zoneSizeHint      = 600000,
  ignoreDuplicates  = true,
  extendedErrorCode = 15,
  extendedErrorExtra= "blocked: malware/threat feed",
})

-- Kids only - discarded for everyone else in policy.lua.
rpzFile("/var/lib/powerdns/rpz/adult.rpz", {
  policyName        = "adult",
  zoneSizeHint      = 200000,
  ignoreDuplicates  = true,
  extendedErrorCode = 15,
  extendedErrorExtra= "blocked: adult content",
})

rpzFile("/var/lib/powerdns/rpz/social.rpz", {
  policyName        = "social",
  zoneSizeHint      = 2000,
  ignoreDuplicates  = true,
  extendedErrorCode = 15,
  extendedErrorExtra= "blocked: social media",
})
