## isonim_email/transport/mailpit.nim — the Mailpit catcher.
##
## `sendMailpit` SMTP-injects one message into the local Mailpit
## catcher and waits for it to land, returning the Mailpit id;
## the readback helpers (`mailpitTotal`, `waitForLatest`, `fetchRaw`,
## `fetchSummary`) are the test's view into the catcher. Thin on
## purpose — production senders use their own transports.
##
## C backend only: sockets + HTTP.

import std/[httpclient, json, os]
import ./smtp
import ../target

## The client families an edit to this module can change: read by
## the capture CLI to pick the families of an `--affected` run.
const affects*: set[ClientFamily] = {}

export smtp

type MailpitError* = object of CatchableError
  ## The catcher is unreachable, or the message never landed.

const
  mailpitPollStepMs* = 100
  mailpitWaitMs* = 10_000

proc mailpitTotal*(httpBase: string): int =
  ## Messages currently held (`GET /api/v1/messages`).
  var client = newHttpClient(timeout = smtpTimeoutMs)
  try:
    let body = client.getContent(httpBase & "/api/v1/messages")
    body.parseJson()["total"].getInt()
  except HttpRequestError as e:
    raise newException(MailpitError,
      "Mailpit: GET " & httpBase & "/api/v1/messages failed: " & e.msg)
  except JsonParsingError as e:
    raise newException(MailpitError,
      "Mailpit: unparseable /api/v1/messages reply: " & e.msg)
  finally:
    client.close()

proc waitForLatest*(httpBase: string; before: int;
                   timeoutMs = mailpitWaitMs): string =
  ## Polls until the catcher holds more than `before` messages and
  ## returns the newest id (the list is newest-first). Raises
  ## `MailpitError` on timeout.
  var waited = 0
  while true:
    var client = newHttpClient(timeout = smtpTimeoutMs)
    try:
      let node = client.getContent(
        httpBase & "/api/v1/messages?limit=1").parseJson()
      if node["total"].getInt() > before and
          node["messages"].len > 0:
        return node["messages"][0]["ID"].getStr()
    except HttpRequestError as e:
      raise newException(MailpitError,
        "Mailpit: GET " & httpBase & " failed while waiting: " & e.msg)
    except JsonParsingError as e:
      raise newException(MailpitError,
        "Mailpit: unparseable reply while waiting: " & e.msg)
    finally:
      client.close()
    if waited >= timeoutMs:
      raise newException(MailpitError,
        "Mailpit: no new message within " & $timeoutMs & " ms")
    sleep(mailpitPollStepMs)
    waited += mailpitPollStepMs

proc fetchRaw*(httpBase, id: string): string =
  ## The untouched raw bytes (`GET /api/v1/message/{ID}/raw`).
  var client = newHttpClient(timeout = smtpTimeoutMs)
  try:
    client.getContent(httpBase & "/api/v1/message/" & id & "/raw")
  except HttpRequestError as e:
    raise newException(MailpitError,
      "Mailpit: GET /api/v1/message/" & id & "/raw failed: " & e.msg)
  finally:
    client.close()

proc fetchSummary*(httpBase, id: string): JsonNode =
  ## The parsed summary (`GET /api/v1/message/{ID}`): Mailpit's own
  ## decoded `Text`/`HTML` plus the parsed headers — the independent
  ## oracle for the round trip.
  var client = newHttpClient(timeout = smtpTimeoutMs)
  try:
    client.getContent(
      httpBase & "/api/v1/message/" & id).parseJson()
  except HttpRequestError as e:
    raise newException(MailpitError,
      "Mailpit: GET /api/v1/message/" & id & " failed: " & e.msg)
  except JsonParsingError as e:
    raise newException(MailpitError,
      "Mailpit: unparseable /api/v1/message/" & id & " reply: " & e.msg)
  finally:
    client.close()

proc sendMailpit*(m: EmailMessage; host = "127.0.0.1"; port = 1025;
                 httpPort = 8025; deterministicSeed = ""): string =
  ## Injects one message into the catcher over SMTP (no auth, no TLS —
  ## the catcher shape) and returns the Mailpit id of the message that
  ## lands. `httpPort` is the API/UI port; the SMTP and HTTP ports
  ## differ when the test spawns its own catcher. A non-empty
  ## `deterministicSeed` derives the boundaries and a missing
  ## Message-ID, so the round-trip test can compare bytes.
  let httpBase = "http://" & host & ":" & $httpPort
  let before = mailpitTotal(httpBase)
  smtpInject(host, port, m.envelopeFrom, m.envelopeTo,
    toRfc5322(m, deterministicSeed))
  waitForLatest(httpBase, before)
