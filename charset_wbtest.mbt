///|
fn b64(text : String) -> Bytes {
  @base64.decode_lossy(text)
}

///|
test "gb2312 body decodes to the original Chinese text" {
  // GB2312 bytes for the expected Chinese text.
  assert_eq(
    decode_charset(b64("xOO6w6OsysC95w=="), "gb2312"),
    "你好，世界",
  )
}

///|
test "gbk and gb18030 aliases decode the same bytes" {
  let bytes = b64("xOO6w6OsysC95w==")
  for label in ["gbk", "GBK", "GB2312", "gb18030", "cp936", "x-gbk"] {
    assert_eq(decode_charset(bytes, label), "你好，世界")
  }
}

///|
test "big5 body decodes to the original traditional Chinese text" {
  assert_eq(decode_charset(b64("p0GmbqFBpUCsyQ=="), "big5"), "你好，世界")
}

///|
test "shift_jis body decodes to the original Japanese text" {
  assert_eq(
    decode_charset(b64("grGC8YLJgr+CzQ=="), "shift_jis"),
    "こんにちは",
  )
}

///|
test "quoted charset names are accepted" {
  assert_eq(
    decode_charset(b64("xOO6w6OsysC95w=="), "\"GB2312\""),
    "你好，世界",
  )
}

///|
test "utf-8 bodies still decode unchanged" {
  assert_eq(decode_charset(string_to_bytes("你好"), "utf-8"), "你好")
  assert_eq(decode_charset(string_to_bytes("hello"), "us-ascii"), "hello")
}

///|
test "unknown charsets fall back to a lossy read" {
  assert_eq(
    decode_charset(string_to_bytes("plain"), "x-unknown-thing"),
    "plain",
  )
  assert_eq(decode_charset(b64("xOO6w6OsysC95w=="), "").length() > 0, true)
}

///|
test "invalid bytes are replaced instead of failing" {
  // A lone GBK lead byte has no mapping.
  let decoded = decode_charset(b64("/w=="), "gbk")
  assert_eq(decoded, "\u{FFFD}")
}

///|
test "gb2312 encoded words in a header are decoded" {
  // The encoded word carries the same Chinese text as the GB2312 cases.
  assert_eq(
    decode_encoded_words("=?gb2312?B?xOO6w6OsysC95w==?="),
    "你好，世界",
  )
}
