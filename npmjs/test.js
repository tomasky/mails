"use strict";

// Unit tests for the launcher's platform mapping and URL construction. Run
// with `node --test` from this directory.

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

const crypto = require("node:crypto");

const lib = require("./lib.js");

test("maps every supported Node platform-arch to a release target", () => {
  assert.equal(lib.TARGETS["linux-x64"], "linux-x86_64");
  assert.equal(lib.TARGETS["linux-arm64"], "linux-aarch64");
  assert.equal(lib.TARGETS["darwin-arm64"], "darwin-aarch64");
  assert.equal(Object.keys(lib.TARGETS).length, 3);
});

test("resolves the repository slug from package.json", () => {
  assert.equal(lib.repoSlug(), "tomasky/mails");
});

test("tries the pinned version before the latest release", () => {
  const urls = lib.downloadUrls("linux-x86_64");
  assert.equal(urls.length, 2);
  assert.equal(
    urls[0],
    `https://github.com/tomasky/mails/releases/download/v${lib.version()}/mails-linux-x86_64`
  );
  assert.equal(
    urls[1],
    "https://github.com/tomasky/mails/releases/latest/download/mails-linux-x86_64"
  );
});

test("an explicit MAILS_VERSION pins the release and disables the fallback", () => {
  const saved = process.env.MAILS_VERSION;
  process.env.MAILS_VERSION = "0.1.4";
  try {
    assert.deepEqual(lib.downloadUrls("linux-x86_64"), [
      "https://github.com/tomasky/mails/releases/download/v0.1.4/mails-linux-x86_64",
    ]);
    assert.equal(lib.version(), "0.1.4");
  } finally {
    if (saved === undefined) delete process.env.MAILS_VERSION;
    else process.env.MAILS_VERSION = saved;
  }
});

test("reads the tag out of a releases/latest redirect", () => {
  assert.equal(
    lib.parseLatestTag("https://github.com/tomasky/mails/releases/tag/v0.1.5"),
    "v0.1.5"
  );
  assert.equal(
    lib.parseLatestTag("https://github.com/tomasky/mails/releases/tag/v0.2.0/"),
    "v0.2.0"
  );
  assert.equal(lib.parseLatestTag("https://github.com/tomasky/mails/releases"), null);
  assert.equal(lib.parseLatestTag(undefined), null);
});

// The binary is cached under the version it really is, so a 0.1.5 fallback
// can never be mistaken for the 0.1.6 the package pins.
test("a fallback binary is cached under its own version", () => {
  const saved = process.env.MAILS_CACHE_DIR;
  process.env.MAILS_CACHE_DIR = "/tmp/mails-test-cache";
  try {
    assert.equal(
      lib.binaryPath("linux-x86_64", "0.1.5"),
      path.join("/tmp/mails-test-cache", "mails-0.1.5-linux-x86_64")
    );
    assert.notEqual(
      lib.binaryPath("linux-x86_64", "0.1.5"),
      lib.binaryPath("linux-x86_64", lib.version())
    );
  } finally {
    if (saved === undefined) delete process.env.MAILS_CACHE_DIR;
    else process.env.MAILS_CACHE_DIR = saved;
  }
});

// End to end: the pinned release 404s, latest redirects to an older tag, and
// the download lands under that older tag's file name.
test("falls back to latest without renaming the binary", async () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const http = require("node:http");
  const cache = fs.mkdtempSync(path.join(os.tmpdir(), "mails-npm-test-"));
  const body = Buffer.from("#!/bin/sh\necho fake mails\n");
  const digest = crypto.createHash("sha256").update(body).digest("hex");

  const server = http.createServer((req, res) => {
    if (req.url === "/releases/latest") {
      res.writeHead(302, {
        location: "https://github.com/tomasky/mails/releases/tag/v0.1.5",
      });
      res.end();
      return;
    }
    // Only the latest release exists; the pinned version 404s like a real
    // missing tag does.
    if (!req.url.startsWith("/releases/latest/download/")) {
      res.writeHead(404);
      res.end();
      return;
    }
    if (req.url.endsWith("/mails-linux-x86_64")) {
      res.writeHead(200, { "content-length": body.length });
      res.end(body);
      return;
    }
    if (req.url.endsWith("/mails-linux-x86_64.sha256")) {
      res.end(`${digest}  mails-linux-x86_64\n`);
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;

  const savedCache = process.env.MAILS_CACHE_DIR;
  const savedBase = process.env.MAILS_DOWNLOAD_BASE;
  const savedVersion = process.env.MAILS_VERSION;
  const savedReleasesBase = process.env.MAILS_RELEASES_BASE;
  process.env.MAILS_CACHE_DIR = cache;
  delete process.env.MAILS_DOWNLOAD_BASE;
  delete process.env.MAILS_VERSION;
  try {
    // Point every release URL at the local server.
    process.env.MAILS_RELEASES_BASE = `http://127.0.0.1:${port}`;
    const messages = [];
    const realPlatform = process.platform;
    const realArch = process.arch;
    Object.defineProperty(process, "platform", { value: "linux" });
    Object.defineProperty(process, "arch", { value: "x64" });
    let dest;
    try {
      // The pinned release 404s on the local server, so only the fallback runs.
      dest = await lib.ensureBinary({ log: (m) => messages.push(m) });
    } finally {
      Object.defineProperty(process, "platform", { value: realPlatform });
      Object.defineProperty(process, "arch", { value: realArch });
    }
    assert.equal(dest, path.join(cache, "mails-0.1.5-linux-x86_64"));
    assert.equal(fs.existsSync(dest), true);
    assert.equal(fs.existsSync(path.join(cache, `mails-${lib.version()}-linux-x86_64`)), false);
    assert.match(messages.join("\n"), /v\d+\.\d+\.\d+ has not been released; using v0\.1\.5/);
  } finally {
    delete process.env.MAILS_RELEASES_BASE;
    server.close();
    fs.rmSync(cache, { recursive: true, force: true });
    if (savedCache === undefined) delete process.env.MAILS_CACHE_DIR;
    else process.env.MAILS_CACHE_DIR = savedCache;
    if (savedBase === undefined) delete process.env.MAILS_DOWNLOAD_BASE;
    else process.env.MAILS_DOWNLOAD_BASE = savedBase;
    if (savedVersion === undefined) delete process.env.MAILS_VERSION;
    else process.env.MAILS_VERSION = savedVersion;
    if (savedReleasesBase === undefined) delete process.env.MAILS_RELEASES_BASE;
    else process.env.MAILS_RELEASES_BASE = savedReleasesBase;
  }
});

test("MAILS_DOWNLOAD_BASE replaces both default URLs", () => {
  const saved = process.env.MAILS_DOWNLOAD_BASE;
  process.env.MAILS_DOWNLOAD_BASE = "https://mirror.example.com/mails/";
  try {
    assert.deepEqual(lib.downloadUrls("darwin-aarch64"), [
      "https://mirror.example.com/mails/mails-darwin-aarch64",
    ]);
  } finally {
    if (saved === undefined) delete process.env.MAILS_DOWNLOAD_BASE;
    else process.env.MAILS_DOWNLOAD_BASE = saved;
  }
});

test("MAILS_VERSION wins over the package version and tolerates a v prefix", () => {
  const saved = process.env.MAILS_VERSION;
  process.env.MAILS_VERSION = "v9.9.9";
  try {
    assert.equal(lib.version(), "9.9.9");
    assert.match(lib.downloadUrls("linux-aarch64")[0], /\/v9\.9\.9\//);
  } finally {
    if (saved === undefined) delete process.env.MAILS_VERSION;
    else process.env.MAILS_VERSION = saved;
  }
});

test("the cache directory can be redirected", () => {
  const saved = process.env.MAILS_CACHE_DIR;
  process.env.MAILS_CACHE_DIR = "/tmp/mails-test-cache";
  try {
    assert.equal(lib.cacheDir(), "/tmp/mails-test-cache");
    assert.equal(
      lib.binaryPath("linux-x86_64"),
      path.join("/tmp/mails-test-cache", `mails-${lib.version()}-linux-x86_64`)
    );
  } finally {
    if (saved === undefined) delete process.env.MAILS_CACHE_DIR;
    else process.env.MAILS_CACHE_DIR = saved;
  }
});

test("MAILS_BINARY short-circuits every download path", async () => {
  const saved = process.env.MAILS_BINARY;
  process.env.MAILS_BINARY = "/bin/sh";
  try {
    assert.equal(await lib.ensureBinary(), "/bin/sh");
  } finally {
    if (saved === undefined) delete process.env.MAILS_BINARY;
    else process.env.MAILS_BINARY = saved;
  }
});

test("MAILS_BINARY pointing nowhere is a clear error", async () => {
  const saved = process.env.MAILS_BINARY;
  process.env.MAILS_BINARY = "/nonexistent/mails";
  try {
    await assert.rejects(lib.ensureBinary(), /does not exist/);
  } finally {
    if (saved === undefined) delete process.env.MAILS_BINARY;
    else process.env.MAILS_BINARY = saved;
  }
});

test("an unsupported platform explains itself", async () => {
  const saved = process.env.MAILS_BINARY;
  delete process.env.MAILS_BINARY;
  const realPlatform = process.platform;
  const realArch = process.arch;
  try {
    Object.defineProperty(process, "platform", { value: "sunos" });
    Object.defineProperty(process, "arch", { value: "sparc" });
    await assert.rejects(lib.ensureBinary(), /does not ship a binary/);
  } finally {
    Object.defineProperty(process, "platform", { value: realPlatform });
    Object.defineProperty(process, "arch", { value: realArch });
    if (saved === undefined) delete process.env.MAILS_BINARY;
    else process.env.MAILS_BINARY = saved;
  }
});

test("compares versions numerically, not as text", () => {
  assert.equal(lib.compareVersions("1.10.0", "1.9.0") > 0, true);
  assert.equal(lib.compareVersions("0.1.6", "0.1.6"), 0);
  assert.equal(lib.compareVersions("v2.0.0", "1.99.99") > 0, true);
});

test("a cached fallback binary is reused when downloads are disabled", async () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const cache = fs.mkdtempSync(path.join(os.tmpdir(), "mails-npm-skip-"));
  const savedCache = process.env.MAILS_CACHE_DIR;
  const savedSkip = process.env.MAILS_SKIP_DOWNLOAD;
  const savedBinary = process.env.MAILS_BINARY;
  const realPlatform = process.platform;
  const realArch = process.arch;
  process.env.MAILS_CACHE_DIR = cache;
  process.env.MAILS_SKIP_DOWNLOAD = "1";
  delete process.env.MAILS_BINARY;
  Object.defineProperty(process, "platform", { value: "linux" });
  Object.defineProperty(process, "arch", { value: "x64" });
  try {
    const file = path.join(cache, "mails-0.1.5-linux-x86_64");
    fs.writeFileSync(file, "#!/bin/sh\n", { mode: 0o755 });
    const messages = [];
    const dest = await lib.ensureBinary({ log: (m) => messages.push(m) });
    assert.equal(dest, file);
    assert.match(messages.join("\n"), /using the cached v0\.1\.5/);
  } finally {
    Object.defineProperty(process, "platform", { value: realPlatform });
    Object.defineProperty(process, "arch", { value: realArch });
    fs.rmSync(cache, { recursive: true, force: true });
    if (savedCache === undefined) delete process.env.MAILS_CACHE_DIR;
    else process.env.MAILS_CACHE_DIR = savedCache;
    if (savedSkip === undefined) delete process.env.MAILS_SKIP_DOWNLOAD;
    else process.env.MAILS_SKIP_DOWNLOAD = savedSkip;
    if (savedBinary === undefined) delete process.env.MAILS_BINARY;
    else process.env.MAILS_BINARY = savedBinary;
  }
});
