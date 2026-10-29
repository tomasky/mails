///|
test "parse_list_line reads a plain folder" {
  let folder = match
    parse_list_line("* LIST (\\HasNoChildren) \"/\" \"INBOX\"") {
    Some(value) => value
    None => fail("not parsed")
  }
  assert_eq(folder.name, "INBOX")
  assert_eq(folder.delimiter, "/")
  assert_eq(folder.attributes, ["\\HasNoChildren"])
}

///|
test "parse_list_line keeps spaces inside a quoted name" {
  let folder = match
    parse_list_line("* LIST (\\HasChildren) \"/\" \"Sent Items\"") {
    Some(value) => value
    None => fail("not parsed")
  }
  assert_eq(folder.name, "Sent Items")
}

///|
test "parse_list_line reads a NIL delimiter and no attributes" {
  let folder = match parse_list_line("* LIST () NIL inbox") {
    Some(value) => value
    None => fail("not parsed")
  }
  assert_eq(folder.name, "inbox")
  assert_eq(folder.delimiter, "")
}

///|
test "parse_list_line reads several attributes" {
  let folder = match
    parse_list_line("* LIST (\\Noselect \\HasChildren) \"/\" \"Archive/2024\"") {
    Some(value) => value
    None => fail("not parsed")
  }
  assert_eq(folder.attributes, ["\\Noselect", "\\HasChildren"])
  assert_eq(folder_is_noselect(folder), true)
}

///|
test "parse_list_line ignores other replies" {
  assert_true(parse_list_line("* OK done") is None)
  assert_true(parse_list_line("a1 OK LIST completed") is None)
}

///|
/// Build the one-line FETCH reply a server sends for a header-only fetch.
fn header_fetch_line(flags : String, header : String) -> LogicalLine {
  {
    text: "1 FETCH (UID 7 FLAGS (" +
    flags +
    ") RFC822.SIZE 512 BODY[HEADER.FIELDS (DATE FROM SUBJECT)] {" +
    string_to_bytes(header).length().to_string() +
    "}",
    prefixes: [],
    literals: [string_to_bytes(header)],
  }
}

///|
test "parse_header_fetch decodes an encoded subject" {
  let header = "Date: Mon, 27 Oct 2026 10:02:19 +0000\r\n" +
    "From: =?UTF-8?B?5byg5LiJ?= <zhang@example.com>\r\n" +
    "Subject: =?UTF-8?B?5L2g5aW9?=\r\n\r\n"
  let envelope = match parse_header_fetch(header_fetch_line("\\Seen", header)) {
    Some(value) => value
    None => fail("not parsed")
  }
  assert_eq(envelope.uid, "7")
  assert_eq(envelope.subject, "你好")
  assert_eq(envelope.from, "张三 <zhang@example.com>")
  assert_eq(envelope.size, 512)
  assert_eq(envelope.seen, true)
  assert_eq(envelope.flagged, false)
}

///|
test "parse_header_fetch marks unseen mail" {
  let envelope = match
    parse_header_fetch(header_fetch_line("", "Subject: hi\r\n\r\n")) {
    Some(value) => value
    None => fail("not parsed")
  }
  assert_eq(envelope.seen, false)
  assert_eq(envelope.subject, "hi")
}

///|
test "parse_header_fetch rejects a reply without a uid" {
  let line : LogicalLine = {
    text: "1 FETCH (FLAGS (\\Seen))",
    prefixes: [],
    literals: [],
  }
  assert_true(parse_header_fetch(line) is None)
}

///|
test "short_date compacts an RFC 5322 date" {
  assert_eq(short_date("Mon, 27 Oct 2026 10:02:19 +0000"), "2026-10-27 10:02")
  // A single digit day is padded so the column stays straight.
  assert_eq(short_date("Tue, 01 Apr 2025 09:15:00 +0800"), "2025-04-01 09:15")
}

///|
test "short_date passes through what it does not understand" {
  assert_eq(short_date("not a date"), "not a date")
  assert_eq(short_date(""), "")
}

///|
test "fit_width truncates with an ellipsis and counts characters" {
  assert_eq(fit_width("hello", 10), "hello")
  assert_eq(fit_width("hello world", 8), "hello w…")
  // CJK characters count as one column each, not three bytes.
  assert_eq(fit_width("测试测试测试", 6), "测试测试测试")
  assert_eq(fit_width("测试测试测试", 4), "测试测…")
  assert_eq(fit_width("", 4), "")
}

///|
test "pad_to pads with spaces" {
  assert_eq(pad_to("ab", 4), "ab  ")
  assert_eq(pad_to("abcd", 4), "abcd")
  assert_eq(pad_to("abcdef", 4), "abcdef")
}

///|
test "render_envelope_table keeps the columns aligned" {
  let envelopes = [
    {
      uid: "1",
      date: "Mon, 27 Oct 2026 10:02:19 +0000",
      from: "alice@example.com",
      subject: "first",
      size: 10,
      seen: true,
      flagged: false,
    },
    {
      uid: "22",
      date: "Mon, 27 Oct 2026 11:02:19 +0000",
      from: "bob@example.com",
      subject: "second",
      size: 20,
      seen: false,
      flagged: false,
    },
  ]
  let table = render_envelope_table(envelopes)
  let lines = table.split("\n").collect()
  assert_eq(lines.length(), 3)
  // The unseen marker sits in front of the subject.
  assert_false(lines[1].to_owned().contains("* first"))
  assert_true(lines[2].to_owned().contains("* second"))
  // Every subject starts at the same column, which is what makes it a table.
  let column = 3 + 2 + 16 + 2 + 24 + 2 + 2
  assert_eq(lines[0][column:column + 7].to_owned(), "SUBJECT")
  assert_eq(lines[1][column:column + 5].to_owned(), "first")
  assert_eq(lines[2][column:column + 6].to_owned(), "second")
  // No line ends in padding.
  for line in lines {
    assert_eq(trim(line).length(), line.length())
  }
}
