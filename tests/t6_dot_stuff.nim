## SMTP transparency (RFC 5321 §4.5.2): `dotStuff` doubles a leading
## `.` on every line, so no payload line can end the DATA phase early,
## and canonicalises line endings to CRLF on the way (RFC 5321 §2.3.8:
## CR and LF only travel as a pair). The unstuffing below is the
## receiver's rule, written independently: strip one leading `.` from
## every line that has one. No rule claim: R-MIME-07 is the encoder's
## half (QP never starts a line with `.`); this is the transport's.
##
## C backend only: the SMTP transport is socket code and is not built
## for JS.
import std/[strutils, unittest]
import isonim_email

proc unstuff(wire: string): string =
  ## RFC 5321 §4.5.2 receiver side, over CRLF lines.
  var lines = wire.split("\r\n")
  for l in lines.mitems:
    if l.startsWith("."):
      l = l[1 .. ^1]
  lines.join("\r\n")

proc hasTerminator(wire: string): bool =
  ## A line holding exactly "." would end DATA early.
  wire.startsWith(".\r\n") or "\r\n.\r\n" in wire or wire == "." or
    wire.endsWith("\r\n.")

suite "smtp dot-stuffing":
  test "leading dots are doubled on every line":
    check dotStuff("") == ""
    check dotStuff(".") == ".."
    check dotStuff(".hidden\r\n") == "..hidden\r\n"
    check dotStuff("a\r\n.\r\nb\r\n") == "a\r\n..\r\nb\r\n"
    check dotStuff("a\r\n..two\r\n") == "a\r\n...two\r\n"
    # Dots elsewhere are untouched.
    check dotStuff("a.b\r\nend.\r\n") == "a.b\r\nend.\r\n"
    # A payload whose own lines are "." never yields the terminator.
    let hostile = "first\r\n.\r\n.\r\nQUIT\r\n.\r\n"
    let wire = dotStuff(hostile)
    check not hasTerminator(wire)
    check unstuff(wire) == hostile

  test "line endings are canonicalised to CRLF first":
    # Bare LF and bare CR become CRLF, and the dot rule applies after
    # each of them.
    check dotStuff("a\n.b\n") == "a\r\n..b\r\n"
    check dotStuff("a\r.b\r") == "a\r\n..b\r\n"
    check dotStuff("a\r\n\n.\r") == "a\r\n\r\n..\r\n"
    let wire = dotStuff("x\n.\ny\r.\rz")
    check '\n' notin wire.replace("\r\n", "")
    check '\r' notin wire.replace("\r\n", "")
    check not hasTerminator(wire)

  test "a real message round-trips through stuffing":
    # The encoders never emit a leading dot (QP writes `=2E`), so a
    # library message passes through unchanged; a raw payload with dot
    # lines round-trips through the receiver's rule.
    let msg = toMessage(RenderedEmail(html: ".starts with a dot\n.\n",
      text: ".dot\n..two\n"), MessageHeaders(
        fromAddr: mailbox("", "a@example.com"),
        to: @[mailbox("", "b@example.com")]))
    let bytes = toRfc5322(msg, "t")
    check dotStuff(bytes) == bytes
    check unstuff(dotStuff(bytes)) == bytes
