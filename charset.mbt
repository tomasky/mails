///|
/// Map a MIME `charset` parameter to a WHATWG encoding label.
///
/// Returns `""` for names the decoder does not know, so the caller can fall
/// back to a lossy UTF-8 read instead of failing the whole message.
fn charset_label(charset : String) -> String {
  let mut name = charset.trim().to_lower()
  // Headers in the wild carry quotes: `charset="GB2312"`.
  if name.length() >= 2 && name.has_prefix("\"") && name.has_suffix("\"") {
    name = name[1:name.length() - 1].to_owned()
  }
  match name {
    "" => ""
    "cp936" | "ms936" | "windows-936" | "x-gbk" | "gb2312-80" => "gbk"
    "cp950" | "ms950" | "windows-950" => "big5"
    "cp932" | "ms932" | "sjis" | "shift-jis" => "shift_jis"
    "utf8" => "utf-8"
    "usascii" => "us-ascii"
    other => other.to_owned()
  }
}

///|
/// Decode bytes in the named charset.
///
/// Chinese providers (QQ, 163, Tencent Exmail) still send `gb2312`/`gbk`
/// bodies, so a single-byte or UTF-8-only decoder turns them into mojibake.
/// Everything the WHATWG Encoding Standard knows about is supported here:
/// GBK/GB18030, Big5, Shift_JIS, EUC-JP/KR, the ISO-8859 family and more.
/// Undecodable bytes become U+FFFD, and unknown charsets fall back to a lossy
/// UTF-8 read.
pub fn decode_charset(data : Bytes, charset : String) -> String {
  let label = charset_label(charset)
  if label == "" {
    return bytes_to_string_lossy(data)
  }
  match @moon_encoding.decode(data, label) {
    Ok(text) => text
    Err(_) => bytes_to_string_lossy(data)
  }
}
