#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Assemble Docs/Reports/ (GitHub Pages): the OSVVM and coverage HTML plus the
# golden and post-synth suites from their Output/report_status.env.
#
# Typical flow:
#   ./build_run.sh                                   # OSVVM regression + coverage
#   ( cd "../Golden model" && ./build_run.sh )       # golden cross-check
#   ( cd "../Post synth"   && ./build_run_osvvm.sh ) # gate-level (needs Vivado)
#   ./publish_reports.sh                             # -> Docs/Reports/
#
# Usage:  ./publish_reports.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEST="$ROOT/Docs/Reports"

OSVVM_YML="$HERE/OSVVM_OpenJls/OSVVM_OpenJls.yml"
COV_HTML="$HERE/NVC_CodeCoverage/html"
COVDB="$HERE/NVC_CodeCoverage/merged.covdb"
GOLDEN_ENV="$ROOT/Verification/Golden model/Output/report_status.env"
GOLDEN_TSV="$ROOT/Verification/Golden model/Output/golden_image_results.tsv"
PS_OSVVM_ENV="$ROOT/Verification/Post synth/Output/report_status_osvvm.env"
PS_OSVVM_LOG="$ROOT/Verification/Post synth/Output/postsynth_osvvm.log"
PS_GOLDEN_ENV="$ROOT/Verification/Post synth/Output/report_status_golden.env"
PS_GOLDEN_TSV="$ROOT/Verification/Post synth/Output/ps_golden_image_results.tsv"

# hil/ comes from the OpenJLS-Demos sweep; keep it
HIL_TMP=""
if [ -d "$DEST/hil" ]; then
  HIL_TMP="$(mktemp -d)"
  cp -r "$DEST/hil" "$HIL_TMP/"
fi
rm -rf "$DEST"
mkdir -p "$DEST"
if [ -n "$HIL_TMP" ]; then
  cp -r "$HIL_TMP/hil" "$DEST/hil"
  rm -rf "$HIL_TMP"
fi

# Site chrome
mkdir -p "$DEST/assets"
cp "$HERE/report_assets/report.css" "$HERE/report_assets/theme.js" "$DEST/assets/"
for f in openjls-wordmark openjls-wordmark-dark isentropic-wordmark isentropic-wordmark-dark; do
  cp "$ROOT/Docs/Images/$f.svg" "$DEST/assets/"
done
cp "$ROOT/Docs/Images/isentropic-icon-64.png" "$DEST/assets/"

# page_head <title> <asset-prefix> / page_foot <asset-prefix>
page_head() {
  local title="$1" p="$2"
  cat <<HDR
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<link rel="icon" href="${p}assets/isentropic-icon-64.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow:wght@400;500;600;700&family=Barlow+Condensed:wght@400;600&display=swap">
<link rel="stylesheet" href="${p}assets/report.css">
<script src="${p}assets/theme.js"></script>
</head><body>
<nav class="site-nav">
  <a class="brand" href="https://isentropic.com.br" aria-label="Isentropic — home"><img class="wm-light" src="${p}assets/isentropic-wordmark.svg" alt="Isentropic"><img class="wm-dark" src="${p}assets/isentropic-wordmark-dark.svg" alt="Isentropic"></a>
  <a class="nlink" href="https://isentropic.com.br/openjls">OpenJLS</a>
  <a class="nlink" href="https://github.com/isentropic-fpga/OpenJLS">GitHub</a>
  <button type="button" class="theme-btn" data-theme-toggle aria-label="Switch color theme" title="Switch color theme">
    <svg class="ico-moon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/></svg>
    <svg class="ico-sun" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/></svg>
  </button>
</nav>
<main><div class="wrap">
HDR
}
page_foot() {
  cat <<FTR
</div></main>
<footer>
  <span style="font-weight:600;color:var(--color-text);">Isentropic</span>
  <a href="https://isentropic.com.br">isentropic.com.br</a>
  <a href="mailto:contact@isentropic.com.br">contact@isentropic.com.br</a>
  <a href="https://github.com/isentropic-fpga">GitHub</a>
  <span>&copy; $(date -u +%Y)</span>
</footer>
</body></html>
FTR
}

ROWS=""
NOTES=""
# emit_row <name> <note> <status> <pct> <summary> <report-link-or-empty> <date-or-empty>
emit_row() {
  local name="$1" note="$2" status="$3" pct="$4" summary="$5" link="$6" date="$7"
  local cls report
  case "$status" in
    PASS)    cls="ok" ;;
    FAIL)    cls="bad" ;;
    INFO)    cls="info" ;;
    *)       cls="na"; status="not run" ;;
  esac
  if [ -n "$link" ]; then report="<a href=\"$link\">view</a>"; else report="&mdash;"; fi
  ROWS+="    <tr><td class=\"suite\">$name</td><td><span class=\"badge $cls\">$status</span></td>"
  ROWS+="<td class=\"pct\">${pct:-&mdash;}</td><td>${summary:-&mdash;}</td>"
  ROWS+="<td>$report</td><td class=\"date\">${date:-&mdash;}</td></tr>"$'\n'
  [ -n "$note" ] && NOTES+=" <strong>$name.</strong> $note"
  return 0
}

# --- NVC code coverage (HTML tree) ----------------------------------------
if [ -d "$COV_HTML" ]; then
  rm -rf "$DEST/coverage"; cp -r "$COV_HTML" "$DEST/coverage"
  pct=""
  if [ -f "$COVDB" ]; then
    pct=$(cd "$HERE" && python3 cover_summary.py NVC_CodeCoverage ../../Sources 2>/dev/null \
            | awk '/^TOTAL/{print $3}')
  fi
  # The coverage HTML has no date; use its mtime
  cov_date=$(date -u -r "$COV_HTML/index.html" '+%Y-%m-%d' 2>/dev/null || true)
  COV_NOTE="Statement coverage of the RTL, unioned over every OSVVM test; the report breaks it down per source file."
  emit_row "NVC code coverage" "$COV_NOTE" "INFO" \
    "${pct:-n/a}" "per-file breakdown in report" "coverage/index.html" "$cov_date"
else
  emit_row "NVC code coverage" "" "NA" "" \
    "run ./build_run.sh to populate" "" ""
fi

# --- OSVVM regression (HTML tree) -----------------------------------------
if [ -f "$HERE/index.html" ] && [ -f "$OSVVM_YML" ]; then
  mkdir -p "$DEST/osvvm"
  cp -r "$HERE/index.html" "$HERE/OSVVM_OpenJls" "$HERE/osvvm" "$DEST/osvvm/"
  pass=$(grep -c 'Status: PASSED' "$OSVVM_YML" || true)
  fail=$(grep -c 'Status: FAILED' "$OSVVM_YML" || true)
  total=$((pass + fail))
  affirm=$(grep -oE 'AffirmCount: [0-9]+' "$OSVVM_YML" | awk '{s+=$2} END{print s+0}')
  rdate=$(awk -F'"' '/^Date:/{print $2; exit}' "$OSVVM_YML")
  [ -z "$rdate" ] && rdate=$(awk '/^Date:/{print $2; exit}' "$OSVVM_YML")
  st=PASS; [ "$fail" -ne 0 ] && st=FAIL
  opct=$(awk -v p="$pass" -v t="$total" 'BEGIN{ if (t > 0) printf "%.0f%%", 100 * p / t }')
  # Link this build's summary; osvvm/index.html lists stale builds too
  emit_row "OSVVM suite" "Module testbenches against independent T.87 reference models, the top-level control-plane stress test and the AXI wrapper tests, all with requirements tracking." "$st" "$opct" \
    "$total tests &middot; $(printf "%'d" "$affirm") affirmations" \
    "osvvm/OSVVM_OpenJls/OSVVM_OpenJls.html" "${rdate%T*}"
else
  emit_row "OSVVM suite" "" "NA" "" \
    "run ./build_run.sh to populate" "" ""
fi

# --- text-only suites: read their report_status.env ------------------------
# fields: NAME, NOTE, STATUS, PCT, SUMMARY, DATE  (shell key=value, quoted)
env_row() {
  local f="$1" fb_name="$2" fb_note="$3" link="$4"
  if [ ! -f "$f" ]; then
    emit_row "$fb_name" "$fb_note" "NA" "" "run the suite to populate" "" ""
    return
  fi
  local NAME="" NOTE="" STATUS="" PCT="" SUMMARY="" DATE=""
  # shellcheck disable=SC1090
  source "$f"
  emit_row "${NAME:-$fb_name}" "${fb_note:-$NOTE}" "${STATUS:-NA}" "${PCT:-}" \
    "${SUMMARY:-}" "$link" "${DATE%%T*}"
}

# render_tsv_page <tsv> <dest-subdir> <title> -> relative link, empty if no tsv
render_tsv_page() {
  local tsv="$1" sub="$2" title="$3"
  [ -f "$tsv" ] || { echo ""; return; }
  mkdir -p "$DEST/$sub"
  {
    page_head "$title" "../"
    cat <<HDR
<a class="back" href="../index.html">&larr; All reports</a>
<div class="hero" style="margin-top:14px;"><h1 class="text">$title</h1></div>
<div class="tbl-scroll"><table><thead><tr>
HDR
    head -1 "$tsv" | awk -F'\t' '{for (i=1;i<=NF;i++) printf "<th>%s</th>", $i; print ""}'
    echo "</tr></thead><tbody>"
    tail -n +2 "$tsv" | awk -F'\t' '{
      printf "<tr>"
      for (i=1;i<=NF;i++) {
        cls=""
        if ($i=="PASS") cls=" class=\"r-ok\""
        else if ($i ~ /^FAIL/) cls=" class=\"r-bad\""
        else if ($i=="SKIP" || $i=="no result") cls=" class=\"r-na\""
        printf "<td%s>%s</td>", cls, $i
      }
      print "</tr>"
    }'
    echo "</tbody></table></div>"
    page_foot "../"
  } > "$DEST/$sub/index.html"
  echo "$sub/index.html"
}

# render_log_page <log> <dest-subdir> <title> -> relative link; the log as <pre>
render_log_page() {
  local log="$1" sub="$2" title="$3"
  [ -f "$log" ] || { echo ""; return; }
  mkdir -p "$DEST/$sub"
  {
    page_head "$title" "../"
    cat <<HDR
<a class="back" href="../index.html">&larr; All reports</a>
<div class="hero" style="margin-top:14px;"><h1 class="text">$title</h1></div>
<pre class="log">
HDR
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$log"
    echo "</pre>"
    page_foot "../"
  } > "$DEST/$sub/index.html"
  echo "$sub/index.html"
}

golden_link=""
[ -f "$GOLDEN_ENV" ] && golden_link="$(render_tsv_page "$GOLDEN_TSV" golden "Golden model — processed images")"
ps_osvvm_link=""
[ -f "$PS_OSVVM_ENV" ] && ps_osvvm_link="$(render_log_page "$PS_OSVVM_LOG" post-synth-osvvm "Post-synth OSVVM — simulation log")"
ps_golden_link=""
[ -f "$PS_GOLDEN_ENV" ] && ps_golden_link="$(render_tsv_page "$PS_GOLDEN_TSV" post-synth-golden "Post-synth Golden Model — processed images")"

env_row "$GOLDEN_ENV"    "Golden model" \
  "RTL encode of the simulation corpus (images up to 0.5&nbsp;MP, depths 8&ndash;16) compared byte-for-byte with the CharLS reference encoder." \
  "$golden_link"
env_row "$PS_OSVVM_ENV"  "Post-synth OSVVM" \
  "The top-level control-plane stress test re-run on the synthesized gate-level netlist (BITNESS=8, 4096x4096, OUT_WIDTH=64)." \
  "$ps_osvvm_link"
env_row "$PS_GOLDEN_ENV" "Post-synth Golden Model" \
  "8-bit corpus images up to 0.05&nbsp;MP encoded on the gate-level netlist and compared with CharLS; the cap keeps gate-level simulation time bounded." \
  "$ps_golden_link"

# --- hardware-in-the-loop (published out of band from OpenJLS-Demos) ------
if [ -f "$DEST/hil/results.csv" ]; then
  hil_total=$(($(wc -l < "$DEST/hil/results.csv") - 1))
  hil_pass=$(grep -c ',pass,' "$DEST/hil/results.csv" || true)
  hil_status=PASS; hil_pct="100%"
  if [ "$hil_pass" -ne "$hil_total" ]; then
    hil_status=FAIL
    hil_pct="$((100 * hil_pass / hil_total))%"
  fi
  hil_depths=$(awk -F, 'NR>1{if(min==""||$1+0<min)min=$1;if($1+0>max)max=$1} END{print min"&ndash;"max}' "$DEST/hil/results.csv")
  hil_date=$(git -C "$ROOT" log -1 --format=%cs -- "Docs/Reports/hil" 2>/dev/null || true)
  emit_row "Hardware-in-the-loop" "The whole corpus, including the full-size originals too large to simulate, encoded on a PYNQ-Z2 FPGA at depths $hil_depths (one bitstream per depth) by the OpenJLS-Demos EncodeOverEthernet sweep." "$hil_status" "$hil_pct" \
    "$hil_pass of $hil_total images byte-exact vs CharLS on PYNQ-Z2 silicon" \
    "hil/index.html" "$hil_date"
fi

# --- landing page ----------------------------------------------------------
GEN_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
MATRIX="$(python3 "$HERE/matrix_html.py" "$ROOT/Docs/verification_requirements.md")"
{
  page_head "OpenJLS — verification report" ""
  cat <<EOF
<div class="hero">
  <span class="kicker">Verification report</span>
  <h1><img class="wm-light" src="assets/openjls-wordmark.svg" alt="OpenJLS"><img class="wm-dark" src="assets/openjls-wordmark-dark.svg" alt="OpenJLS"></h1>
  <p class="lede">Results from the project's own verification suites for the OpenJLS JPEG-LS (ISO/IEC 14495-1) encoder IP core. Open a row's report for per-test and per-image detail.</p>
</div>
<div class="tbl-scroll"><table>
  <thead><tr><th>Suite</th><th>Status</th><th>Pass / cov</th><th>Summary</th><th>Report</th><th>Run date</th></tr></thead>
  <tbody>
$ROWS  </tbody>
</table></div>
<p class="notes">$NOTES The OSVVM and coverage reports are full HTML; the golden-model, post-synthesis and hardware pages list every image or log line. Generated $GEN_DATE by <code>Verification/OSVVM/publish_reports.sh</code>. <a href="https://isentropic.com.br/openjls">IP core specifications, throughput figures and licensing &rarr;</a></p>
<h2 class="section">Verification matrix</h2>
<p class="notes">Every requirement the OSVVM suite tracks, with the RTL and testbench that cover it, the guaranteed minimum check count per run (Goal) and its status against verification rules G1&ndash;G6: &check; met, N/A not applicable. <strong>G1.</strong> Requirement checked against a golden model transcribed from the T.87 C code. <strong>G2.</strong> Arithmetic ranges asserted in the RTL and driven to min, max and clamp points. <strong>G3.</strong> Safe signed/unsigned conversions and resizes, stimulated with MSB set and most negative values. <strong>G4.</strong> Corner cases: image edges, run mode, coding extremes, BITNESS 8/16, streaming and backpressure. <strong>G5.</strong> Reset from every state recovers the module, checked against a fresh golden run. <strong>G6.</strong> Zero errors, all goals and coverage met, code coverage reviewed. Source: <a href="https://github.com/isentropic-fpga/OpenJLS/blob/main/Docs/verification_requirements.md"><code>Docs/verification_requirements.md</code></a>; rules in <a href="https://github.com/isentropic-fpga/OpenJLS/blob/main/Docs/verification_guidelines.md"><code>Docs/verification_guidelines.md</code></a>.</p>
$MATRIX
EOF
  page_foot ""
} > "$DEST/index.html"

echo "Published report tree -> $DEST"
echo "  open $DEST/index.html"
