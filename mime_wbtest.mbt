///|
/// MIME and RFC 2047 tests, using the same shapes real mail servers return.

///|
test "decodes base64 encoded words" {
  assert_eq(
    decode_encoded_words("=?utf-8?B?VXJnZW50OiBpbnZvaWNlICM0Mg==?="),
    "Urgent: invoice #42",
  )
}

///|
test "decodes quoted-printable encoded words" {
  assert_eq(decode_encoded_words("=?ISO-8859-1?Q?Andr=E9?="), "Andr\u{e9}")
}

///|
test "leaves plain header text alone" {
  assert_eq(decode_encoded_words("plain subject"), "plain subject")
}

///|
test "decodes quoted-printable soft line breaks" {
  let text = bytes_to_string_lossy(
    decode_quoted_printable_bytes("one=\r\ntwo=20three", false),
  )
  assert_eq(text, "onetwo three")
}

///|
test "unfolds continuation header lines" {
  let headers = parse_headers(
    "Subject: a long\r\n subject line\r\nFrom: a@b\r\n",
  )
  assert_eq(header_value(headers, "subject"), "a long subject line")
  assert_eq(header_value(headers, "from"), "a@b")
}

///|
test "prefers the plain part of multipart/alternative" {
  let raw = "Content-Type: multipart/alternative; boundary=XYZ\r\n\r\n" +
    "--XYZ\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" +
    "Plain body talking about an invoice\r\n" +
    "--XYZ\r\nContent-Type: text/html; charset=utf-8\r\n\r\n" +
    "<p>HTML body about an <b>invoice</b></p>\r\n" +
    "--XYZ--\r\n"
  let body = message_body_text(string_to_bytes(raw))
  assert_true(body.contains("Plain body"))
  assert_false(body.contains("HTML body"))
}

///|
test "plain text keeps its line breaks" {
  let raw = "Content-Type: text/plain; charset=utf-8\r\n\r\n" +
    "line one\r\n  indented\r\n\r\nline four\r\n"
  assert_eq(
    message_body_text(string_to_bytes(raw)),
    "line one\n  indented\n\nline four",
  )
}

///|
test "html block tags become line breaks" {
  let raw = "Content-Type: text/html; charset=utf-8\r\n\r\n" +
    "<html><body>\n  <p>Invoice <b>#42</b><br>due tomorrow</p>\n" +
    "  <p>Total: 100</p>\n</body></html>"
  assert_eq(
    message_body_text(string_to_bytes(raw)),
    "Invoice #42\ndue tomorrow\n\nTotal: 100",
  )
}

///|
test "falls back to stripped html when there is no plain part" {
  let raw = "Content-Type: text/html; charset=utf-8\r\n\r\n" +
    "<html><style>p{color:red}</style><body><p>Hello &amp; welcome</p></body></html>"
  let body = message_body_text(string_to_bytes(raw))
  assert_eq(body, "Hello & welcome")
}

///|
test "decodes base64 bodies" {
  let encoded = base64_encode(string_to_bytes("invoice inside"))
  let raw = "Content-Type: text/plain; charset=utf-8\r\n" +
    "Content-Transfer-Encoding: base64\r\n\r\n" +
    encoded
  assert_eq(message_body_text(string_to_bytes(raw)), "invoice inside")
}

///|
test "skips attachments in multipart/mixed" {
  let attachment = base64_encode(string_to_bytes("binary payload here"))
  let raw = "Content-Type: multipart/mixed; boundary=M\r\n\r\n" +
    "--M\r\nContent-Type: text/plain\r\n\r\nvisible text\r\n" +
    "--M\r\nContent-Type: application/octet-stream\r\n" +
    "Content-Disposition: attachment; filename=a.bin\r\n" +
    "Content-Transfer-Encoding: base64\r\n\r\n" +
    attachment +
    "\r\n--M--\r\n"
  let body = message_body_text(string_to_bytes(raw))
  assert_eq(body, "visible text")
}

///|
test "build_message decodes subject and picks fields" {
  let header = string_to_bytes(
    "From: Alice <alice@example.com>\r\n" +
    "Subject: =?utf-8?Q?Invoice_=2342?=\r\n" +
    "Content-Type: text/plain\r\n\r\n",
  )
  let body = string_to_bytes("Please pay it.")
  let message = build_message("INBOX", "7", 120, header, body)
  assert_eq(message.subject, "Invoice #42")
  assert_eq(message.from, "Alice <alice@example.com>")
  assert_eq(message.body, "Please pay it.")
  assert_eq(message.uid, "7")
}

///|
test "multipart headers can be passed separately from the body" {
  let headers = parse_headers(
    "Content-Type: multipart/alternative; boundary=XYZ\r\n",
  )
  let body = "--XYZ\r\nContent-Type: text/plain\r\n\r\nplain part\r\n" +
    "--XYZ\r\nContent-Type: text/html\r\n\r\n<p>html part</p>\r\n" +
    "--XYZ--\r\n"
  let text = message_body_text_with_headers(headers, string_to_bytes(body))
  assert_eq(text, "plain part")
}

///|
test "gb2312 body survives the mime walker" {
  // A QQ/163-style message: GB2312 body, 8bit transfer encoding.
  let header = string_to_bytes(
    "Subject: =?gb2312?B?xOO6w6OsysC95w==?=\r\n" +
    "Content-Type: text/plain; charset=gb2312\r\n" +
    "Content-Transfer-Encoding: 8bit\r\n\r\n",
  )
  let body = @base64.decode_lossy("xOO6w6OsysC95w==")
  let message = build_message("INBOX", "1", 100, header, body)
  assert_eq(message.subject, "你好，世界")
  assert_eq(message.body, "你好，世界")
}

///|
test "gb2312 quoted-printable body decodes" {
  // GB2312 quoted-printable bytes for the expected Chinese body.
  let header = string_to_bytes(
    "Content-Type: text/plain; charset=gb2312\r\n" +
    "Content-Transfer-Encoding: quoted-printable\r\n\r\n",
  )
  let body = string_to_bytes("=C4=E3=BA=C3")
  let message = build_message("INBOX", "2", 50, header, body)
  assert_eq(message.body, "你好")
}

///|
test "gb2312 part inside a multipart message decodes" {
  let header = string_to_bytes(
    "Subject: =?gb2312?B?xOO6w6OsysC95w==?=\r\n" +
    "Content-Type: multipart/alternative; boundary=\"b1\"\r\n\r\n",
  )
  let body = string_to_bytes(
      "--b1\r\n" +
      "Content-Type: text/plain; charset=gb2312\r\n" +
      "Content-Transfer-Encoding: 8bit\r\n\r\n",
    ) +
    @base64.decode_lossy("xOO6w6OsysC95w==") +
    string_to_bytes("\r\n--b1--\r\n")
  let message = build_message("INBOX", "3", 200, header, body)
  assert_eq(message.body, "你好，世界")
}

///|
test "base64 gb2312 body decodes" {
  let header = string_to_bytes(
    "Content-Type: text/plain; charset=gb2312\r\n" +
    "Content-Transfer-Encoding: base64\r\n\r\n",
  )
  let body = string_to_bytes("xOO6w6OsysC95w==\r\n")
  let message = build_message("INBOX", "4", 60, header, body)
  assert_eq(message.body, "你好，世界")
}
