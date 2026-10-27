#!/usr/bin/env node
// Launcher for the native `mails` binary.
//
// The package ships no install script, so this is where the binary is fetched:
// on the first run, straight into the user cache. Arguments, stdio, signals and
// the exit code are all forwarded to the real binary.
"use strict";

const { spawn } = require("child_process");
const { ensureBinary } = require("../lib.js");

const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"];

async function main() {
  let binary;
  try {
    binary = await ensureBinary({
      log: (line) => process.stderr.write(`${line}\n`),
    });
  } catch (err) {
    process.stderr.write(`mails: ${err.message}\n`);
    process.exit(1);
  }

  const child = spawn(binary, process.argv.slice(2), { stdio: "inherit" });

  // Forward signals so Ctrl-C reaches the daemon-facing CLI rather than
  // killing only the wrapper and orphaning the child.
  for (const signal of SIGNALS) {
    process.on(signal, () => {
      try {
        child.kill(signal);
      } catch {
        /* already gone */
      }
    });
  }

  child.on("error", (err) => {
    process.stderr.write(`mails: failed to launch ${binary}: ${err.message}\n`);
    process.exit(1);
  });

  child.on("exit", (code, signal) => {
    if (signal) {
      // Mirror the child's death by signal instead of inventing an exit code.
      process.removeAllListeners(signal);
      process.kill(process.pid, signal);
      return;
    }
    process.exit(code === null ? 1 : code);
  });
}

main().catch((err) => {
  process.stderr.write(`mails: ${err && err.stack ? err.stack : err}\n`);
  process.exit(1);
});
