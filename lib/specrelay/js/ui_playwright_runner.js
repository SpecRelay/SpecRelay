#!/usr/bin/env node
// ui_playwright_runner.js — real Playwright adapter for UI runtime
// verification (spec 0028, section 16, "Playwright execution").
//
// This script is invoked by py/ui_verification_lib.py's
// `_playwright_run_scenario` exactly once per scenario: it receives one JSON
// object on stdin (`{scenario, base_url, browser}`) and MUST print exactly
// one JSON object on stdout with the SAME shape the fake provider produces
// (`{blocked_reason, steps, assertions, console_events, network_events,
// screenshots}` — screenshots carry base64-encoded PNG bytes under
// `raw_bytes_b64`, decoded by the Python caller) so the deterministic engine
// treats both providers identically past this point (spec section 6: "the
// deterministic engine owns scenario selection, execution boundaries,
// artifact paths, retention limits, and completion gates" — never this
// adapter). It never decides PASS/FAIL/BLOCKED itself; it only reports raw
// facts.
//
// Requires the CONSUMING project's own `playwright` package (this project,
// SpecRelay itself, has no browser UI to point this at, so its own test
// suite always runs with provider: fake instead).

const fs = require("fs");

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

async function runStep(page, step) {
  switch (step.action) {
    case "goto":
      await page.goto(step.url, { waitUntil: "load" });
      return;
    case "click":
      await page.locator(`text=${step.target}`).first().click();
      return;
    case "fill":
      await page.locator(step.target).fill(step.value || "");
      return;
    case "select":
      await page.locator(step.target).selectOption(step.value);
      return;
    case "check":
      await page.locator(step.target).check();
      return;
    case "uncheck":
      await page.locator(step.target).uncheck();
      return;
    case "hover":
      await page.locator(step.target).hover();
      return;
    case "press":
      await page.keyboard.press(step.key || step.target);
      return;
    case "wait_for":
      await page.locator(step.target).waitFor({ state: step.state || "visible" });
      return;
    default:
      throw new Error(`unsupported step action: ${step.action}`);
  }
}

async function runAssertion(page, assertion) {
  const locator = assertion.target ? page.locator(`text=${assertion.target}`).first() : null;
  switch (assertion.type) {
    case "visible":
      await locator.waitFor({ state: "visible", timeout: 5000 });
      return true;
    case "absent":
      return (await locator.count()) === 0;
    case "text":
      return (await locator.innerText()).includes(assertion.value || "");
    case "value":
      return (await locator.inputValue()) === assertion.value;
    case "url":
      return page.url().includes(assertion.value || "");
    case "count":
      return (await page.locator(assertion.target).count()) === assertion.value;
    default:
      throw new Error(`unsupported assertion type: ${assertion.type}`);
  }
}

async function main() {
  const raw = await readStdin();
  const input = JSON.parse(raw);
  const scenario = input.scenario;
  const result = {
    blocked_reason: null,
    steps: [],
    assertions: [],
    console_events: [],
    network_events: [],
    screenshots: [],
  };

  let playwright;
  try {
    playwright = require("playwright");
  } catch (err) {
    result.blocked_reason = "playwright npm package is not installed in this project";
    process.stdout.write(JSON.stringify(result));
    return;
  }

  const browserType = playwright[input.browser || "chromium"];
  const browser = await browserType.launch();
  const traceMode = input.trace_mode || "off";
  const tracePath = traceMode !== "off" ? `${require("os").tmpdir()}/specrelay-ui-trace-${process.pid}.zip` : null;
  let context;
  try {
    context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    if (tracePath) {
      await context.tracing.start({ screenshots: true, snapshots: true });
    }
    const page = await context.newPage();

    page.on("console", (msg) => {
      result.console_events.push({ level: msg.type() === "error" ? "error" : "warning", text: msg.text(), url: page.url() });
    });
    page.on("response", (response) => {
      result.network_events.push({ status: response.status(), method: response.request().method(), url: response.url() });
    });

    if (input.base_url) {
      await page.goto(input.base_url, { waitUntil: "load" }).catch(() => {});
    }

    for (const [i, step] of scenario.steps.entries()) {
      try {
        await runStep(page, step);
        result.steps.push({ index: i, action: step.action, ok: true });
      } catch (err) {
        result.steps.push({ index: i, action: step.action, ok: false, detail: String(err.message || err) });
      }
    }

    for (const [i, assertion] of (scenario.assertions || []).entries()) {
      try {
        const ok = await runAssertion(page, assertion);
        result.assertions.push({ index: i, ...assertion, ok });
      } catch (err) {
        result.assertions.push({ index: i, ...assertion, ok: false, detail: String(err.message || err) });
      }
    }

    for (const checkpoint of scenario.checkpoints || []) {
      let bytes;
      const locatorSpec = checkpoint.region && checkpoint.region.locator;
      if (locatorSpec) {
        bytes = await page.locator(locatorSpec).screenshot();
      } else {
        bytes = await page.screenshot();
      }
      result.screenshots.push({ checkpoint_id: checkpoint.id, raw_bytes_b64: bytes.toString("base64") });
    }
  } catch (err) {
    result.blocked_reason = `playwright execution failed: ${String(err.message || err)}`;
  } finally {
    if (tracePath && context) {
      try {
        await context.tracing.stop({ path: tracePath });
        result.trace_b64 = fs.readFileSync(tracePath).toString("base64");
      } catch (_err) {
        // Tracing is best-effort diagnostic evidence; never let a tracing
        // failure mask the scenario's real result.
      } finally {
        try {
          fs.unlinkSync(tracePath);
        } catch (_err) {
          // already removed or never created
        }
      }
    }
    await browser.close();
  }

  process.stdout.write(JSON.stringify(result));
}

main().catch((err) => {
  process.stderr.write(String((err && err.stack) || err));
  process.exit(1);
});
