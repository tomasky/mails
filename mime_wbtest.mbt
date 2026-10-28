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

///|
/// Chinese providers often leave the charset out of the MIME headers and only
/// declare it in the HTML, which used to decode as UTF-8 mojibake.
test "reads the charset from an html meta tag when the header omits it" {
  let gbk = match @moon_encoding.encode("你好，世界", "gbk") {
    Ok(bytes) => bytes
    Err(_) => abort("gbk encoder missing")
  }
  let out : Array[Byte] = []
  for
    byte in @utf8.encode(
      "Content-Type: text/html\r\n\r\n<html><head><meta charset=\"gb2312\"></head><body>",
    ) {
    out.push(byte)
  }
  for byte in gbk {
    out.push(byte)
  }
  for byte in @utf8.encode("</body></html>") {
    out.push(byte)
  }
  assert_eq(message_body_text(Bytes::from_array(out[:])), "你好，世界")
}

///|
test "ignores a charset mention outside a meta tag" {
  let raw = "Content-Type: text/html\r\n\r\n" +
    "<p>ask about charset=gb2312 in a ticket</p>"
  assert_eq(
    message_body_text(string_to_bytes(raw)),
    "ask about charset=gb2312 in a ticket",
  )
}

///|
/// `has_prefix("<p")` used to also match `<param>` and `<picture>`, adding
/// line breaks the message does not have.
test "does not break lines on tags that merely start with a break tag name" {
  let raw = "Content-Type: text/html; charset=utf-8\r\n\r\n" +
    "<para>alpha</para><param name=x><picture><source src=x></picture>" +
    "<link rel=x><option>opt</option>"
  let text = message_body_text(string_to_bytes(raw))
  assert_eq(text, "alphaopt")
}

///|
/// Quoted-printable bodies from Chinese providers use hard CRLF line breaks,
/// which the decoder used to drop, flattening the whole message to one line.
test "quoted-printable keeps hard line breaks" {
  let raw = "Content-Type: text/plain; charset=utf-8\r\n" +
    "Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
    "=E6=98=A8=E5=A4=A9=E5=AE=8C=E6=88=90=E7=9A=84=E5=B7=A5=E4=BD=9C=EF=BC=9A\r\n\r\n1. =E4=B8=BA Arrow Unbound =E5=87=86=E5=A4=87=E7=B4=A0=E6=9D=90=E3=80=82\r\n\r\n2. =E5=B7=B4=E8=A5=BF=EF=BC=9AOffer 616844=E3=80=82\r\n"
  assert_eq(
    message_body_text(string_to_bytes(raw)),
    "昨天完成的工作：\n\n1. 为 Arrow Unbound 准备素材。\n\n2. 巴西：Offer 616844。",
  )
}

///|
/// A soft break only means "this line was too long for the encoder", so it has
/// to disappear without leaving a break behind.
test "quoted-printable drops soft line breaks" {
  let raw = "Content-Type: text/plain; charset=utf-8\r\n" +
    "Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
    "=E4=BD=A0=\r\n=E5=A5=BD=EF=BC=8C=\r\n=E4=B8=96=E7=95=8C"
  assert_eq(message_body_text(string_to_bytes(raw)), "你好，世界")
}

///|
test "quoted-printable keeps a stray equals sign" {
  let raw = "Content-Type: text/plain; charset=utf-8\r\n" +
    "Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
    "a = b =zz"
  assert_eq(message_body_text(string_to_bytes(raw)), "a = b =zz")
}

///|
/// The same code path carries HTML parts, which are quoted-printable just as
/// often; the paragraphs still have to survive.
test "quoted-printable html keeps its paragraphs" {
  let raw = "Content-Type: text/html; charset=utf-8\r\n" +
    "Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
    "<div>=E7=AC=AC=E4=B8=80=E6=AE=B5</div>\r\n" +
    "<div>=E7=AC=AC=E4=BA=8C=E6=AE=B5</div>"
  assert_eq(message_body_text(string_to_bytes(raw)), "第一段\n\n第二段")
}

///|
/// A multipart message with one quoted-printable part per language: the rule
/// keyword has to be found and the line structure kept.
test "multipart quoted-printable keeps every part's line breaks" {
  let raw = "Content-Type: multipart/mixed; boundary=BND\r\n\r\n" +
    "--BND\r\n" +
    "Content-Type: text/plain; charset=utf-8\r\n" +
    "Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
    "line one\r\nline two\r\n" +
    "--BND--\r\n"
  assert_eq(message_body_text(string_to_bytes(raw)), "line one\nline two")
}
