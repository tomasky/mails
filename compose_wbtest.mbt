///|
test "rfc5322_date renders a known instant" {
  // 2024-02-29T23:59:59Z, the leap day that catches most day-count bugs.
  assert_eq(rfc5322_date(1709251199L), "Thu, 29 Feb 2024 23:59:59 +0000")
  // The Unix epoch is a Thursday, which is where the weekday offset comes from.
  assert_eq(rfc5322_date(0L), "Thu, 01 Jan 1970 00:00:00 +0000")
  assert_eq(rfc5322_date(86400L), "Fri, 02 Jan 1970 00:00:00 +0000")
}

///|
test "rfc5322_date handles a century boundary" {
  // 2100 is not a leap year, unlike 2000; the day count has to agree with a
  // real calendar, not just with an offset from the epoch.
  assert_eq(rfc5322_date(4102444799L), "Thu, 31 Dec 2099 23:59:59 +0000")
}

///|
test "encode_header_text leaves ascii alone" {
  assert_eq(encode_header_text("plain ascii"), "plain ascii")
  assert_eq(encode_header_text(""), "")
}

///|
test "encode_header_text encodes non-ascii as a single word" {
  assert_eq(encode_header_text("测试"), "=?UTF-8?B?5rWL6K+V?=")
}

///|
test "encode_header_text splits long values without breaking a character" {
  // 40 CJK characters are 120 bytes, so this needs three encoded words, and
  // every word has to decode on its own.
  let text = "测".repeat(40)
  let encoded = encode_header_text(text)
  assert_true(encoded.has_prefix("=?UTF-8?B?"))
  let mut decoded = ""
  for word in encoded.split(" ") {
    assert_true(word.has_prefix("=?UTF-8?B?"))
    assert_true(word.has_suffix("?="))
    let payload = word[10:word.length() - 2].to_owned()
    decoded = decoded + bytes_to_string_lossy(base64_decode(payload))
  }
  assert_eq(decoded, text)
}

///|
test "base64_body wraps at 76 characters" {
  let text = "a".repeat(200) // 200 bytes -> 268 base64 chars
  let encoded = base64_body(string_to_bytes(text))
  for line in encoded.split("\n") {
    // Lines are CRLF terminated, so the CR is not part of the count.
    assert_true(trim(line).length() <= 76)
  }
  let joined = encoded.replace_all(old="\r\n", new="")
  assert_eq(bytes_to_string_lossy(base64_decode(joined)), text)
}

///|
test "make_message_id uses the domain of the sender" {
  let id = make_message_id("me@example.com", 1000L, "abc")
  assert_eq(id, "<mails.1000.abc@example.com>")
  // No domain to fall back on.
  assert_eq(make_message_id("weird", 1L, "u"), "<mails.1.u@mails.local>")
}

///|
test "render_outgoing_message writes the expected headers" {
  let draft = {
    from: "me@example.com",
    to: ["a@example.com"],
    cc: [],
    bcc: ["secret@example.com"],
    subject: "hi",
    body: "one\ntwo\n",
    html: false,
    attachments: [],
  }
  let message = render_outgoing_message(draft, 1700000000L, "deadbeef")
  assert_true(message.contains("From: me@example.com\r\n"))
  assert_true(message.contains("To: a@example.com\r\n"))
  assert_true(message.contains("Subject: hi\r\n"))
  assert_true(message.contains("Date: Tue, 14 Nov 2023 22:13:20 +0000\r\n"))
  assert_true(message.contains("Content-Type: text/plain; charset=utf-8\r\n"))
  // Bcc must never reach the message itself.
  assert_false(message.contains("secret@example.com"))
  assert_false(message.contains("Bcc"))
}

///|
test "render_outgoing_message keeps the body line breaks" {
  let draft = {
    from: "me@example.com",
    to: ["a@example.com"],
    cc: [],
    bcc: [],
    subject: "s",
    body: "one\r\ntwo\nthree",
    html: false,
    attachments: [],
  }
  let message = render_outgoing_message(draft, 0L, "u")
  let split = match message.find("\r\n\r\n") {
    Some(index) => (message[:index].to_owned(), message[index + 4:].to_owned())
    None => fail("no header separator")
  }
  let (_, body) = split
  let decoded = base64_decode(body.replace_all(old="\r\n", new=""))
  assert_eq(bytes_to_string_lossy(decoded), "one\ntwo\nthree")
}

///|
test "render_outgoing_message builds multipart/mixed with attachments" {
  let draft = {
    from: "me@example.com",
    to: ["a@example.com"],
    cc: ["b@example.com"],
    bcc: [],
    subject: "with file",
    body: "see attached",
    html: false,
    attachments: [
      { name: "/tmp/x/note.txt", mime: "text/plain", data: b"hello", },
    ],
  }
  let message = render_outgoing_message(draft, 0L, "u")
  assert_true(message.contains("Content-Type: multipart/mixed; boundary=\""))
  assert_true(message.contains("Cc: b@example.com\r\n"))
  assert_true(
    message.contains("Content-Disposition: attachment; filename=\"note.txt\""),
  )
  // Two parts, so the closing boundary has to be there.
  let after = match message.find("boundary=\"") {
    Some(index) => message[index + 10:].to_owned()
    None => fail("no boundary parameter")
  }
  let end = match after.find("\"") {
    Some(index) => index
    None => fail("unterminated boundary parameter")
  }
  let marker = "--" + after[:end].to_owned()
  assert_true(message.contains(marker + "\r\n"))
  assert_true(message.contains(marker + "--\r\n"))
}

///|
test "render_outgoing_message uses text/html when asked" {
  let draft = {
    from: "me@example.com",
    to: ["a@example.com"],
    cc: [],
    bcc: [],
    subject: "s",
    body: "<p>hi</p>",
    html: true,
    attachments: [],
  }
  let message = render_outgoing_message(draft, 0L, "u")
  assert_true(message.contains("Content-Type: text/html; charset=utf-8\r\n"))
}

///|
test "render_outgoing_message falls back to (no subject)" {
  let draft = {
    from: "me@example.com",
    to: ["a@example.com"],
    cc: [],
    bcc: [],
    subject: "   ",
    body: "x",
    html: false,
    attachments: [],
  }
  assert_true(
    render_outgoing_message(draft, 0L, "u").contains("Subject: (no subject)"),
  )
}

///|
test "guess_mime_type knows the common extensions" {
  assert_eq(guess_mime_type("a.txt"), "text/plain; charset=utf-8")
  assert_eq(guess_mime_type("a.PDF"), "application/pdf")
  assert_eq(guess_mime_type("a.png"), "image/png")
  assert_eq(guess_mime_type("a.tar.gz"), "application/gzip")
  assert_eq(guess_mime_type("a.unknown"), "application/octet-stream")
}

///|
test "draft_recipients merges To, Cc and Bcc without duplicates" {
  let draft = {
    from: "me@example.com",
    to: ["a@example.com"],
    cc: ["b@example.com", "a@example.com"],
    bcc: ["c@example.com"],
    subject: "",
    body: "",
    html: false,
    attachments: [],
  }
  assert_eq(draft_recipients(draft), [
    "a@example.com", "b@example.com", "c@example.com",
  ])
}
