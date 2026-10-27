///|
/// mails executable entry point. All real work lives in the `kupas/mails`
/// package so it can be tested and reused.

///|
extern "C" fn mails_exit(status : Int32) -> Unit = "mails_exit"

///|
async fn main {
  if !@mailslib.main_cli() {
    mails_exit(1)
  }
}
