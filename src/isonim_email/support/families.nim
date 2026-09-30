## isonim_email/support/families.nim — caniemail client keys → ClientFamily.
##
## Maps the `family/platform` keys of `caniemail_data.nim` to the
## `ClientFamily` families. caniemail has no separate new-Outlook column,
## so `outlook-com` stands in for it (the new Outlook shares the
## OWA/Outlook.com codebase). Two deliberate gaps:
##
## - `outlook/windows-mail` is unmapped: Windows Mail stopped working at
##   the end of 2024, so it is excluded.
## - The French/German webmails (`orange`, `sfr`, `free-fr`, `laposte`,
##   `gmx`, `web-de`, `t-online-de`, `ionos-1and1`, `mail-ru`, `rainloop`,
##   `wp-pl`) have no family: the profiles spread their "others" remainder
##   across the thirteen families instead, so every weight is assessable.
##
## `cfGanga` shares the Gmail-app keys: caniemail has no GANGA column
## (GANGA is a Gmail-app mode, not a client). Its extra strictness — no
## head CSS at all — is a lint rule, not data (it lands with the
## head-CSS assembly).
##
## Family support is the worst of its keys (`n` < `a` < `y`, `u` skipped):
## one current client lacking a feature means the family lacks it. This is
## the conservative reading, and the right one for email.

import ../target
import ./caniemail_data

export target
export caniemail_data

proc familyClients*(f: ClientFamily): seq[string] =
  ## The caniemail keys feeding a family.
  case f
  of cfApple: @["apple-mail/ios", "apple-mail/macos"]
  of cfGmailWeb: @["gmail/desktop-webmail", "gmail/mobile-webmail"]
  of cfGmailApp: @["gmail/ios", "gmail/android"]
  of cfGanga: @["gmail/ios", "gmail/android"]
  of cfOutlookWord: @["outlook/windows"]
  of cfOutlookWeb: @["outlook/outlook-com"]
  of cfOutlookApp: @["outlook/macos", "outlook/ios", "outlook/android"]
  of cfYahoo:
    @["yahoo/desktop-webmail", "yahoo/ios", "yahoo/android",
      "aol/desktop-webmail", "aol/ios", "aol/android"]
  of cfSamsung: @["samsung-email/android"]
  of cfThunderbird: @["thunderbird/macos", "thunderbird/windows"]
  of cfProton:
    @["protonmail/desktop-webmail", "protonmail/ios", "protonmail/android"]
  of cfFastmail: @["fastmail/desktop-webmail"]
  of cfHey: @["hey/desktop-webmail"]

proc isMappedClient*(key: string): bool =
  ## True when some family claims `key`.
  for f in ClientFamily:
    if key in familyClients(f):
      return true
  false

type FamilySupport* = object
  value*: SupportValue
  witnesses*: seq[string] ## Keys exhibiting `value` (empty when unknown)
  notes*: seq[int]        ## Note ids cited by the witnesses

proc familySupport*(slug: string; f: ClientFamily): FamilySupport =
  ## Worst support of `slug` across the family's keys. Unknown slugs, and
  ## families whose keys all read unknown, yield `svUnknown`.
  var worst = svYes
  var found = false
  for key in familyClients(f):
    let (val, _) = supportFor(slug, key)
    if val == svUnknown:
      continue
    found = true
    if val == svNo:
      worst = svNo
    elif val == svPartial and worst == svYes:
      worst = svPartial
  if not found:
    return FamilySupport(value: svUnknown, witnesses: @[], notes: @[])
  var witnesses: seq[string] = @[]
  var notes: seq[int] = @[]
  for key in familyClients(f):
    let (val, cellNotes) = supportFor(slug, key)
    if val == worst:
      witnesses.add(key)
      for n in cellNotes:
        if n notin notes:
          notes.add(n)
  FamilySupport(value: worst, witnesses: witnesses, notes: notes)

proc unsupportedFamilies*(slug: string): set[ClientFamily] =
  ## Families where `slug` reads `svNo`. Partial (`svPartial`) counts as
  ## supported here: caniemail partials overwhelmingly restrict exotic
  ## syntax (e.g. Yahoo's border-radius `a` is only about the elliptical
  ## `/` shorthand), and counting them as gaps would warn on bread-and-
  ## butter CSS — `margin` and `text-align` are partial in seven families.
  ## Unknown (`svUnknown`) abstains: no data, no diagnostic.
  for f in ClientFamily:
    if familySupport(slug, f).value == svNo:
      result.incl(f)
