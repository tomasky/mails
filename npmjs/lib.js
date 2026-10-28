"use strict";

// Shared logic for the npm launcher: work out which prebuilt `mails` binary
// belongs on this machine, and fetch it from GitHub Releases on demand.
//
// mails deliberately ships **no install script**. As of npm 12 dependency
// lifecycle scripts are blocked unless the user opts in, and pnpm 12 fails a
// *project* install outright with ERR_PNPM_IGNORED_BUILDS when a dependency
// declares one. Downloading on first run works under every package manager,
// under `--ignore-scripts`, and under `npx`, so that is what this does.
//
// Overrides (all optional):
//   MAILS_REPO            owner/repo       (default: tomasky/mails)
//   MAILS_VERSION         release version  (default: this package's version);
//                         setting it pins that version and disables the
//                         fallback to the latest release
//   MAILS_RELEASES_BASE   host serving the releases (default: GitHub)
//   MAILS_DOWNLOAD_BASE   full base URL    (overrides MAILS_REPO/MAILS_VERSION)
//   MAILS_CACHE_DIR       where the binary is kept
//   MAILS_BINARY          run this binary and never download
//   MAILS_FORCE_DOWNLOAD  re-download even if the binary is already present
//   MAILS_SKIP_DOWNLOAD   never download; fail if the binary is absent
//   MAILS_NO_VERIFY       skip SHA-256 verification

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const http = require("http");

const pkg = require("./package.json");

// Node's `platform-arch` -> the release target name. Intel macOS is absent on
// purpose: the MoonBit toolchain no longer ships a darwin-x86_64 target.
const TARGETS = {
  "linux-x64": "linux-x86_64",
  "linux-arm64": "linux-aarch64",
  "darwin-arm64": "darwin-aarch64",
};

const SUPPORTED = "linux-x86_64, linux-aarch64 and darwin-aarch64";

function targetName() {
  return TARGETS[`${process.platform}-${process.arch}`];
}

function repoSlug() {
  if (process.env.MAILS_REPO) return process.env.MAILS_REPO;
  const url =
    typeof pkg.repository === "string"
      ? pkg.repository
      : (pkg.repository && pkg.repository.url) || "";
  const m = url.match(/github\.com[/:]([^/]+)\/([^/.]+)/);
  return m ? `${m[1]}/${m[2]}` : "tomasky/mails";
}

function version() {
  return (process.env.MAILS_VERSION || pkg.version).replace(/^v/, "");
}

function assetName(target) {
  return `mails-${target}`;
}

// Everything below is resolved against this prefix, so a mirror or a GitHub
// Enterprise host can serve the releases too.
function releaseBase() {
  return (
    process.env.MAILS_RELEASES_BASE || `https://github.com/${repoSlug()}`
  ).replace(/\/+$/, "");
}

function pinnedUrl(target) {
  return `${releaseBase()}/releases/download/v${version()}/${assetName(target)}`;
}

function latestUrl(target) {
  return `${releaseBase()}/releases/latest/download/${assetName(target)}`;
}

// The pinned version first, then whatever is latest. The fallback keeps the
// launcher useful when package.json was bumped ahead of the tag, but it is
// marked as such: the binary is cached under *its own* version, never the
// pinned one, so `mails version` keeps telling the truth. An explicit
// MAILS_VERSION pins the version and disables the fallback entirely.
//
// `version: null` means "resolve the tag first, the version is not known yet".
function downloadAttempts(target) {
  const asset = assetName(target);
  if (process.env.MAILS_DOWNLOAD_BASE) {
    const base = process.env.MAILS_DOWNLOAD_BASE.replace(/\/+$/, "");
    return [{ url: `${base}/${asset}`, version: version(), fallback: false }];
  }
  const attempts = [
    { url: pinnedUrl(target), version: version(), fallback: false },
  ];
  if (!process.env.MAILS_VERSION) {
    attempts.push({ url: latestUrl(target), version: null, fallback: true });
  }
  return attempts;
}

function downloadUrls(target) {
  return downloadAttempts(target).map((attempt) => attempt.url);
}

// `https://github.com/o/r/releases/tag/v0.1.5` -> `v0.1.5`.
function parseLatestTag(location) {
  const m = String(location || "").match(/\/releases\/tag\/([^/?#]+)\/?$/);
  return m ? m[1] : null;
}

// Which tag `releases/latest` currently points at. The redirect is read
// without following it, so this costs one request and no download. Knowing the
// tag is what lets the fallback binary keep its real version.
function latestTag() {
  return new Promise((resolve, reject) => {
    const url = `${releaseBase()}/releases/latest`;
    const client = url.startsWith("http:") ? http : https;
    const req = client.request(
      url,
      {
        method: "HEAD",
        headers: { "user-agent": `mails-npm/${pkg.version}` },
      },
      (res) => {
        res.resume();
        const tag = parseLatestTag(res.headers.location);
        if (tag) resolve(tag);
        else {
          reject(
            new Error(
              `cannot tell which version ${url} points at (HTTP ${res.statusCode}); ` +
                `set MAILS_VERSION to choose one explicitly`
            )
          );
        }
      }
    );
    req.on("error", reject);
    req.setTimeout(30000, () =>
      req.destroy(new Error(`timed out asking ${url}`))
    );
    req.end();
  });
}

function cacheDir() {
  if (process.env.MAILS_CACHE_DIR) return process.env.MAILS_CACHE_DIR;
  const home = os.homedir();
  if (process.platform === "darwin") {
    return path.join(home, "Library", "Caches", "mails");
  }
  const base = process.env.XDG_CACHE_HOME || path.join(home, ".cache");
  return path.join(base, "mails");
}

// The version in the file name is the version of the binary inside it, which
// is not always the version this package pins: see `downloadUrls`.
function binaryPath(target, binaryVersion) {
  return path.join(
    cacheDir(),
    `mails-${binaryVersion || version()}-${target}`
  );
}

// Every runnable binary already in the cache for `target`, newest version
// first. A fallback download is stored under its own version, so this is how
// it is found again when the pinned release still does not exist.
function cachedVersions(target) {
  const suffix = `-${target}`;
  let names;
  try {
    names = fs.readdirSync(cacheDir());
  } catch {
    return [];
  }
  const found = [];
  for (const name of names) {
    if (!name.startsWith("mails-") || !name.endsWith(suffix)) continue;
    const version = name.slice("mails-".length, name.length - suffix.length);
    const file = path.join(cacheDir(), name);
    if (/^\d+\.\d+\.\d+/.test(version) && isRunnable(file)) {
      found.push({ version, file });
    }
  }
  found.sort((a, b) => compareVersions(b.version, a.version));
  return found;
}

// `1.10.0` is newer than `1.9.0`, which a plain string compare gets wrong.
function compareVersions(a, b) {
  const parse = (v) =>
    String(v)
      .replace(/^v/, "")
      .split(/[.+-]/)
      .map((n) => parseInt(n, 10) || 0);
  const pa = parse(a);
  const pb = parse(b);
  for (let i = 0; i < Math.max(pa.length, pb.length); i += 1) {
    const diff = (pa[i] || 0) - (pb[i] || 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function isRunnable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// --- HTTP ------------------------------------------------------------------

function fetch(url, redirects) {
  return new Promise((resolve, reject) => {
    if (redirects > 10) {
      reject(new Error("too many redirects"));
      return;
    }
    const client = url.startsWith("http:") ? http : https;
    const req = client.get(
      url,
      { headers: { "user-agent": `mails-npm/${pkg.version}` } },
      (res) => {
        const { statusCode, headers } = res;
        if (statusCode >= 300 && statusCode < 400 && headers.location) {
          res.resume();
          resolve(fetch(new URL(headers.location, url).toString(), redirects + 1));
          return;
        }
        if (statusCode !== 200) {
          res.resume();
          const err = new Error(`GET ${url} -> HTTP ${statusCode}`);
          err.statusCode = statusCode;
          reject(err);
          return;
        }
        resolve(res);
      }
    );
    req.on("error", reject);
    req.setTimeout(120000, () => req.destroy(new Error(`timed out fetching ${url}`)));
  });
}

async function fetchBuffer(url) {
  const res = await fetch(url, 0);
  const chunks = [];
  for await (const chunk of res) chunks.push(chunk);
  return Buffer.concat(chunks);
}

async function fetchText(url) {
  return (await fetchBuffer(url)).toString("utf8");
}

// --- install ---------------------------------------------------------------

// Download to a sibling temp file and rename into place, so a crashed or
// concurrent run can never leave a half-written binary at `dest`.
async function downloadTo(url, dest) {
  const res = await fetch(url, 0);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const tmp = `${dest}.${process.pid}.${Date.now()}.part`;
  try {
    await new Promise((resolve, reject) => {
      const out = fs.createWriteStream(tmp, { mode: 0o755 });
      res.pipe(out);
      out.on("finish", () => out.close(resolve));
      out.on("error", reject);
      res.on("error", reject);
    });
    const size = fs.statSync(tmp).size;
    if (size === 0) throw new Error(`${url} returned an empty file`);
    fs.chmodSync(tmp, 0o755);
    fs.renameSync(tmp, dest);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
}

// Verify against the `<asset>.sha256` published next to the binary. A missing
// checksum is a warning, not a failure, so older releases keep working.
async function verify(dest, url, log) {
  if (process.env.MAILS_NO_VERIFY) return;
  let published;
  try {
    published = (await fetchText(`${url}.sha256`)).trim();
  } catch {
    log(`mails: warning: no checksum published for ${path.basename(url)}`);
    return;
  }
  const expected = (published.split(/\s+/)[0] || "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(expected)) {
    log("mails: warning: published checksum is not a SHA-256 digest");
    return;
  }
  const actual = crypto.createHash("sha256").update(fs.readFileSync(dest)).digest("hex");
  if (actual !== expected) {
    fs.rmSync(dest, { force: true });
    throw new Error(
      `checksum mismatch for ${path.basename(url)}\n` +
        `  expected ${expected}\n  actual   ${actual}`
    );
  }
}

/**
 * Resolve to a runnable `mails` binary, downloading it when it is missing.
 *
 * When the pinned version has no release yet, the latest release is used, but
 * it is kept under its own version: the cache file name, the path returned and
 * the warning all name the version that actually runs.
 */
async function ensureBinary({ force = false, log = () => {} } = {}) {
  if (process.env.MAILS_BINARY) {
    if (!fs.existsSync(process.env.MAILS_BINARY)) {
      throw new Error(
        `MAILS_BINARY points at ${process.env.MAILS_BINARY}, which does not exist`
      );
    }
    return process.env.MAILS_BINARY;
  }

  const target = targetName();
  if (!target) {
    throw new Error(
      `mails does not ship a binary for ${process.platform}/${process.arch}; ` +
        `supported: ${SUPPORTED}. Build from source instead: ` +
        `https://github.com/${repoSlug()}#build-from-source`
    );
  }

  const wanted = force || process.env.MAILS_FORCE_DOWNLOAD;
  const want = version();
  const dest = binaryPath(target, want);
  if (!wanted && isRunnable(dest)) return dest;

  if (process.env.MAILS_SKIP_DOWNLOAD) {
    if (isRunnable(dest)) return dest;
    // A fallback binary from an earlier run is stored under its own version.
    const cached = cachedVersions(target);
    if (cached.length > 0) {
      log(
        `mails: warning: v${want} is not in the cache; ` +
          `using the cached v${cached[0].version}`
      );
      return cached[0].file;
    }
    throw new Error(
      `MAILS_SKIP_DOWNLOAD is set but no mails binary is installed in ${cacheDir()}`
    );
  }

  const failures = [];
  for (const attempt of downloadAttempts(target)) {
    // A fallback attempt carries no version until the tag is resolved.
    let binaryVersion = attempt.version;
    if (attempt.fallback) {
      try {
        binaryVersion = String(await latestTag()).replace(/^v/, "");
      } catch (err) {
        failures.push(`${attempt.url}: ${err.message}`);
        log(`mails: ${err.message}`);
        continue;
      }
      if (binaryVersion !== want) {
        log(
          `mails: warning: v${want} has not been released; ` +
            `using v${binaryVersion}, which is the latest release`
        );
      }
    }
    const dest = binaryPath(target, binaryVersion);
    if (!wanted && isRunnable(dest)) {
      log(`mails: using ${dest}`);
      return dest;
    }
    try {
      log(`mails: downloading ${attempt.url}`);
      await downloadTo(attempt.url, dest);
      await verify(dest, attempt.url, log);
      log(`mails: installed ${dest} (v${binaryVersion})`);
      return dest;
    } catch (err) {
      failures.push(`${attempt.url}: ${err.message}`);
      log(`mails: ${err.message}`);
    }
  }

  throw new Error(
    `could not download the mails binary for ${target}.\n` +
      `Tried:\n${failures.map((f) => `  ${f}`).join("\n")}\n\n` +
      `Install it another way instead:\n` +
      `  curl -LsSf https://raw.githubusercontent.com/${repoSlug()}/master/install.sh | bash\n` +
      `or set MAILS_DOWNLOAD_BASE to a mirror.`
  );
}

module.exports = {
  pkg,
  TARGETS,
  SUPPORTED,
  targetName,
  repoSlug,
  version,
  assetName,
  downloadUrls,
  downloadAttempts,
  releaseBase,
  cachedVersions,
  compareVersions,
  latestTag,
  parseLatestTag,
  pinnedUrl,
  latestUrl,
  cacheDir,
  binaryPath,
  isRunnable,
  ensureBinary,
};
