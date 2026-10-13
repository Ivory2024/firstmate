# Drive the live crew dashboard page in headless Chromium and capture:
#  - a full-page screenshot of the 작헝 현황 (queue board) sub-panel
#  - the rendered text of summary counts, column headers, notes, meta line
import json
import os
import sys

from playwright.sync_api import sync_playwright

PORT = os.environ.get("PORT", "8770")
SHOT = os.environ.get("SHOT", "board.png")

with sync_playwright() as p:
    browser = p.chromium.launch()  # chromium-headless-shell
    page = browser.new_page(viewport={"width": 1380, "height": 900})
    js_errors = []

    def on_error(msg):
        js_errors.append(str(msg))

    page.on("pageerror", on_error)
    page.on("console", lambda m: js_errors.append(f"console.{m.type}: {m.text}") if m.type == "error" else None)
    page.goto(f"http://127.0.0.1:{PORT}/", wait_until="networkidle")
    try:
        page.wait_for_function(
            "() => { const el = document.getElementById('qc-queued');"
            " return el && el.textContent !== '?' && el.textContent.trim() !== ''; }",
            timeout=15000)
    except Exception:
        pass  # report whatever is on screen anyway
    page.wait_for_timeout(800)

    def grab(sel):
        try:
            return page.locator(sel).first.text_content()
        except Exception:
            return "(missing)"

    summary = {
        "qc_flight": grab("#qc-flight"),
        "qc_queued": grab("#qc-queued"),
        "qc_stuck": grab("#qc-stuck"),
        "qmeta": grab("#qmeta"),
        "qn_flight": grab("#qn-flight"),
        "qn_queued": grab("#qn-queued"),
        "qn_stuck": grab("#qn-stuck"),
        "qnote_queued": grab("#q-queued .qnote"),
        "queued_row_count": page.locator("#q-queued .qrow").count(),
        "stuck_row_count": page.locator("#q-stuck .qrow").count(),
        "blocked_rows": page.locator("#q-stuck .qrow.blk").count(),
        "held_rows": page.locator("#q-stuck .qrow.hld").count(),
        "stuck_first_rows": page.locator("#q-stuck .qrow .qt").all_text_contents(),
        "queued_first_rows": page.locator("#q-queued .qrow .qt").all_text_contents()[:6],
        "flight_first_rows": page.locator("#q-flight .qrow .qt").all_text_contents(),
        "open_panel": page.locator("#qwrap").get_attribute("open"),
    }
    print("RENDER_SUMMARY " + json.dumps(summary, ensure_ascii=False, indent=2))
    print("JS_ERRORS " + json.dumps(js_errors))
    page.screenshot(path=SHOT, full_page=True)
    browser.close()