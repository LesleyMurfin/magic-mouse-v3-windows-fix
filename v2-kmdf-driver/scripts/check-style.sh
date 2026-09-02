#!/usr/bin/env bash
# scripts/check-style.sh
# M12 Style-Guide Enforcer — AI-tell detector and commit/PR gate.
#
# Usage:
#   check-style.sh [--files file1 file2 ...]   # scan specific files
#   check-style.sh [--diff]                    # scan files changed in current git diff (staged + unstaged)
#   check-style.sh [--staged]                  # scan only staged files
#   check-style.sh [--branch <branch>]         # scan files changed vs given branch
#
# Outputs:
#   style-results.json     — structured violations (in repo root)
#   style-report.md        — human-readable for PR comments (in repo root)
#
# Exit codes:
#   0 = pass (no hard-fail violations)
#   1 = fail (one or more hard-reject violations)
#
# Checks:
#   1. Comment density (>25% => REJECT)
#   2. TODO/FIXME/HACK/XXX in diff (=> REJECT)
#   3. Generic identifier names (=> FLAG)
#   4. Mixed casing styles in same file (=> REJECT)
#   5. Over-defensive null checks after _In_ params (=> WARN)
#   6. Helper functions with <3 callers (=> FLAG)
#   7. Pool tag presence (not 'M12 ' => REJECT)
#   8. clang-format compliance (=> REJECT)
#
# Severity legend:
#   REJECT  — hard fail; blocks commit/PR; exit 1
#   FLAG    — soft; surfaced in report but does not block alone
#   WARN    — advisory; informational only

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo "$(dirname "$0")/..")"
RESULTS_JSON="$REPO_ROOT/style-results.json"
RESULTS_MD="$REPO_ROOT/style-report.md"
CLANG_FORMAT_CFG="$REPO_ROOT/driver/.clang-format"

# ---- timestamp (Calgary / Mountain) ----
if command -v python3 >/dev/null 2>&1; then
    TIMESTAMP=$(python3 -c "
import datetime, zoneinfo
tz = zoneinfo.ZoneInfo('America/Edmonton')
print(datetime.datetime.now(tz).strftime('%Y-%m-%d %H:%M %Z'))
" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
else
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

# ---- argument parsing ----
MODE="diff"
FILES=()
BRANCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --files)
            MODE="files"
            shift
            while [[ $# -gt 0 && "$1" != --* ]]; do
                FILES+=("$1")
                shift
            done
            ;;
        --diff)
            MODE="diff"
            shift
            ;;
        --staged)
            MODE="staged"
            shift
            ;;
        --branch)
            MODE="branch"
            BRANCH="${2:-main}"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ---- collect target files ----
collect_files() {
    local -n _out=$1
    case "$MODE" in
        files)
            _out=("${FILES[@]}")
            ;;
        diff)
            mapfile -t _out < <(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null | grep -E '\.(c|h)$' || true)
            # also include staged
            local staged=()
            mapfile -t staged < <(git -C "$REPO_ROOT" diff --name-only --cached 2>/dev/null | grep -E '\.(c|h)$' || true)
            for f in "${staged[@]}"; do
                local found=false
                for e in "${_out[@]}"; do [[ "$e" == "$f" ]] && found=true && break; done
                $found || _out+=("$f")
            done
            ;;
        staged)
            mapfile -t _out < <(git -C "$REPO_ROOT" diff --name-only --cached 2>/dev/null | grep -E '\.(c|h)$' || true)
            ;;
        branch)
            mapfile -t _out < <(git -C "$REPO_ROOT" diff --name-only "${BRANCH}...HEAD" 2>/dev/null | grep -E '\.(c|h)$' || true)
            ;;
    esac

    # resolve to absolute paths; skip non-existent
    local resolved=()
    for f in "${_out[@]}"; do
        local abs_f
        if [[ "$f" = /* ]]; then
            abs_f="$f"
        else
            abs_f="$REPO_ROOT/$f"
        fi
        [[ -f "$abs_f" ]] && resolved+=("$abs_f")
    done
    _out=("${resolved[@]}")
}

declare -a TARGET_FILES=()
collect_files TARGET_FILES

# ---- violation tracking ----
# Senior-dev review CRIT-3: previous heredoc-based JSON accumulator broke on
# apostrophes / quotes in detail strings (e.g. "doesn't", common in English
# comments). Now we write each violation as one JSONL line to a temp file via
# Python argv (no shell interpolation into Python source); consolidate in
# a single final pass. Eliminates injection class entirely.
VIOLATIONS_JSONL=$(mktemp -t mm-style-violations.XXXXXX.jsonl)
trap 'rm -f "$VIOLATIONS_JSONL"' EXIT
HAS_REJECT=false

add_violation() {
    local file="$1" check="$2" severity="$3" line="$4" detail="$5"
    # Pass strings via argv — Python sees them as bytes-literal string objects
    # so any single/double-quote, backslash, or $-sign in detail is benign.
    python3 -c '
import json, sys
out = sys.argv[1]
record = {
    "file": sys.argv[2],
    "check": sys.argv[3],
    "severity": sys.argv[4],
    "line": sys.argv[5],
    "detail": sys.argv[6],
}
with open(out, "a") as f:
    f.write(json.dumps(record) + "\n")
' "$VIOLATIONS_JSONL" "$file" "$check" "$severity" "$line" "$detail"
    if [[ "$severity" == "REJECT" ]]; then
        HAS_REJECT=true
    fi
}

# ---- helper: portable line count ----
count_lines() {
    wc -l < "$1" | tr -d ' '
}

# ---- CHECK 1: Comment density ----
# Ratio of comment lines (// or /* ... */) to non-blank code lines.
# Reject if >25%.
check_comment_density() {
    local file="$1"
    local rel_file="${file#$REPO_ROOT/}"

    local result
    result=$(python3 - "$file" <<'PYEOF'
import sys, re

file = sys.argv[1]
with open(file, 'r', errors='replace') as f:
    lines = f.readlines()

comment_lines = 0
code_lines = 0
in_block = False

for raw in lines:
    line = raw.strip()
    if not line:
        continue
    if in_block:
        comment_lines += 1
        if '*/' in line:
            in_block = False
        continue
    if line.startswith('//'):
        comment_lines += 1
        continue
    if '/*' in line:
        comment_lines += 1
        if '*/' not in line.split('/*', 1)[1]:
            in_block = True
        continue
    code_lines += 1

total = comment_lines + code_lines
if total == 0:
    ratio = 0.0
else:
    ratio = comment_lines / total

print(f"{comment_lines} {code_lines} {ratio:.4f}")
PYEOF
)

    local comment_lines code_lines ratio
    read -r comment_lines code_lines ratio <<< "$result"

    # compare with python for portability
    local reject
    reject=$(python3 -c "print('yes' if float('$ratio') > 0.25 else 'no')")

    if [[ "$reject" == "yes" ]]; then
        local pct
        pct=$(python3 -c "print(f'{float(\"$ratio\")*100:.1f}')")
        add_violation "$rel_file" "comment-density" "REJECT" "-" \
            "Comment ratio ${pct}% exceeds 25% limit (${comment_lines} comment lines / $((comment_lines + code_lines)) total). Microsoft samples run 5-15%."
    fi
}

# ---- CHECK 2: TODO/FIXME/HACK/XXX ----
# Grep raw diff for these markers.
check_todo_fixme() {
    local file="$1"
    local rel_file="${file#$REPO_ROOT/}"

    # grep returns non-zero when no match; suppress that
    local matches
    matches=$(grep -n -E '\b(TODO|FIXME|HACK|XXX)\b' "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        while IFS= read -r match_line; do
            local lineno="${match_line%%:*}"
            local content="${match_line#*:}"
            add_violation "$rel_file" "todo-fixme" "REJECT" "$lineno" \
                "Found marker in code: ${content// /,}. Open a tracked issue instead."
        done <<< "$matches"
    fi
}

# ---- CHECK 3: Generic identifier names ----
# Pattern: common AI-tell names used as identifiers.
# FLAG (not reject) — context-dependent.
check_generic_names() {
    local file="$1"
    local rel_file="${file#$REPO_ROOT/}"

    local pattern='\b(helper|util|data|buffer|temp|tmp|dummy|placeholder|var)[0-9]*\b'
    local matches
    matches=$(grep -n -E "$pattern" "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        while IFS= read -r match_line; do
            local lineno="${match_line%%:*}"
            local content="${match_line#*:}"
            # skip if it appears inside a string literal (heuristic: in quotes)
            if echo "$content" | grep -qE '"[^"]*'"$pattern"'[^"]*"' 2>/dev/null; then
                continue
            fi
            local word
            word=$(echo "$content" | grep -oE "$pattern" | head -1)
            add_violation "$rel_file" "generic-name" "FLAG" "$lineno" \
                "Generic identifier '${word}' detected. Use domain-specific WDF/HID terms (reqContext, devCtx, batteryStatus, etc.)."
        done <<< "$matches"
    fi
}

# ---- CHECK 4: Mixed casing styles in same file ----
# Detect presence of BOTH snake_case tokens AND camelCase tokens.
# We look at non-preprocessor identifiers only.
check_mixed_casing() {
    local file="$1"
    local rel_file="${file#$REPO_ROOT/}"

    local result
    result=$(python3 - "$file" <<'PYEOF'
import sys, re

file = sys.argv[1]
with open(file, 'r', errors='replace') as f:
    src = f.read()

# Strip string literals and comments for cleaner analysis
src = re.sub(r'"(?:[^"\\]|\\.)*"', '', src)
src = re.sub(r"'(?:[^'\\]|\\.)*'", '', src)
src = re.sub(r'//[^\n]*', '', src)
src = re.sub(r'/\*.*?\*/', '', src, flags=re.DOTALL)
# Strip preprocessor directives
src = re.sub(r'^\s*#[^\n]*', '', src, flags=re.MULTILINE)

# Extract identifiers
idents = re.findall(r'\b[A-Za-z_][A-Za-z0-9_]{2,}\b', src)

has_snake = False
has_camel = False

for ident in idents:
    # Skip all-caps (constants/macros), all-lower with no underscore, WDF prefixes
    if ident.isupper():
        continue
    if re.match(r'^(NTSTATUS|BOOLEAN|PVOID|ULONG|UCHAR|USHORT|VOID|TRUE|FALSE|NULL|PDRIVER_OBJECT|PUNICODE_STRING|WDFDRIVER|WDFDEVICE|WDFREQUEST|WDFQUEUE|WDFTIMER|WDFWORKITEM|WDFMEMORY|WDFIOTARGET|WDFFILEOBJECT|WDFUSBDEVICE|WDFUSBPIPE|STATUS_SUCCESS|STATUS_PENDING|STATUS_UNSUCCESSFUL)$', ident):
        continue
    # snake_case: has underscore and lower letters around it
    if '_' in ident and re.search(r'[a-z]_[a-z]', ident):
        has_snake = True
    # camelCase: lowercase followed immediately by uppercase (not after underscore)
    if re.search(r'[a-z][A-Z]', ident):
        has_camel = True
    if has_snake and has_camel:
        break

print('mixed' if (has_snake and has_camel) else 'ok')
PYEOF
)

    if [[ "$result" == "mixed" ]]; then
        add_violation "$rel_file" "mixed-casing" "REJECT" "-" \
            "File mixes snake_case and camelCase identifiers. Kernel driver files must use one consistent style (WDF convention: camelCase for locals, PascalCase for types, M12Prefix for functions)."
    fi
}

# ---- CHECK 5: Over-defensive null checks after _In_ params ----
# Pattern: function with _In_ annotated parameter, followed closely by
#   if (param == NULL) return STATUS_INVALID_PARAMETER;
# This is flagged as soft WARN — DV proves _In_ is never NULL at entry.
check_defensive_null() {
    local file="$1"
    local rel_file="${file#$REPO_ROOT/}"

    local result
    result=$(python3 - "$file" <<'PYEOF'
import sys, re

file = sys.argv[1]
with open(file, 'r', errors='replace') as f:
    lines = f.readlines()

# Find _In_ annotated parameter names from function signatures
in_params = []
in_func_sig = False
brace_depth = 0
sig_lines = []

findings = []

for i, line in enumerate(lines, 1):
    # Collect potential function signature lines (up to opening brace)
    stripped = line.strip()
    # Simple heuristic: look for _In_ in a line with a type pattern
    if re.search(r'_In_\s+\w+\s+\*?\s*(\w+)', line):
        m = re.findall(r'_In_\s+\w+[\w\s\*]*\s+\*?\s*(\w+)\s*[,\)]', line)
        for param in m:
            in_params.append((param, i))

# For each _In_ param, look for null check within 20 lines
for param, param_line in in_params:
    search_start = param_line
    search_end = min(param_line + 20, len(lines) + 1)
    for j in range(search_start, search_end):
        chk_line = lines[j - 1] if j <= len(lines) else ''
        # Pattern: if (X == NULL) return STATUS_INVALID_PARAMETER
        if re.search(rf'if\s*\(\s*{re.escape(param)}\s*==\s*NULL\s*\)', chk_line):
            if re.search(r'STATUS_INVALID_PARAMETER', chk_line) or (
                j < len(lines) and re.search(r'STATUS_INVALID_PARAMETER', lines[j])
            ):
                findings.append(f"{j}:{param}")
                break

for f in findings:
    print(f)
PYEOF
)

    if [[ -n "$result" ]]; then
        while IFS= read -r hit; do
            local lineno="${hit%%:*}"
            local param="${hit#*:}"
            add_violation "$rel_file" "defensive-null-check" "WARN" "$lineno" \
                "Null check on _In_ parameter '${param}': DV guarantees _In_ is non-NULL at entry. Use NT_ASSERT for debug-mode validation only; remove the runtime check."
        done <<< "$result"
    fi
}

# ---- CHECK 6: Helper function with <3 callers ----
# Identify static functions and count their call sites within the file.
# Functions called <3 times are flagged for review (DRY threshold).
check_helper_callers() {
    local file="$1"
    local rel_file="${file#$REPO_ROOT/}"

    local result
    result=$(python3 - "$file" <<'PYEOF'
import sys, re

file = sys.argv[1]
with open(file, 'r', errors='replace') as f:
    src = f.read()
lines = src.splitlines()

# Find static function definitions (non-WDF-callback, non-entry-point)
# Pattern: static <type> <FunctionName>(
static_funcs = []
for i, line in enumerate(lines, 1):
    m = re.match(r'\s*(?:_\w+_\s+)*static\s+\w[\w\s\*]+\s+(\w+)\s*\(', line)
    if m:
        name = m.group(1)
        # Skip well-known framework entry points that should have 1 caller
        if re.match(r'^(DriverEntry|EvtDriver|EvtDevice|EvtIo|EvtTimer|EvtWorkItem|EvtFile)', name):
            continue
        static_funcs.append((name, i))

# Count call sites (calls, not the definition line)
findings = []
for name, def_line in static_funcs:
    # Match name followed by ( but not in a declaration/definition context
    call_pattern = re.compile(r'\b' + re.escape(name) + r'\s*\(')
    call_sites = []
    for i, line in enumerate(lines, 1):
        if i == def_line:
            continue  # skip the definition line itself
        if call_pattern.search(line):
            call_sites.append(i)
    if 0 < len(call_sites) < 3:
        findings.append(f"{def_line}:{name}:{len(call_sites)}")

for f in findings:
    print(f)
PYEOF
)

    if [[ -n "$result" ]]; then
        while IFS= read -r hit; do
            IFS=: read -r lineno fname callers <<< "$hit"
            add_violation "$rel_file" "helper-few-callers" "FLAG" "$lineno" \
                "Static function '${fname}' has only ${callers} caller(s). DRY threshold is 3+. Inline unless growth is planned; document rationale if kept."
        done <<< "$result"
    fi
}

# ---- CHECK 7: Pool tag presence ----
# Every ExAllocatePoolWithTag / WdfMemoryCreate must use tag 'M12 '.
# Any other tag => REJECT.
check_pool_tags() {
    local file="$1"
    local rel_file="${file#$REPO_ROOT/}"

    local result
    result=$(python3 - "$file" <<'PYEOF'
import sys, re

file = sys.argv[1]
with open(file, 'r', errors='replace') as f:
    lines = f.readlines()

# Patterns for pool allocation calls that take a tag argument
alloc_patterns = [
    # ExAllocatePoolWithTag(type, size, tag)
    re.compile(r'\bExAllocatePoolWithTag\s*\([^)]*?,\s*[^)]*?,\s*([^)]+?)\s*\)'),
    # ExAllocatePool2(flags, size, tag)
    re.compile(r'\bExAllocatePool2\s*\([^)]*?,\s*[^)]*?,\s*([^)]+?)\s*\)'),
    # WdfMemoryCreate(Attributes, PoolType, PoolTag, BufferSize, ...) — PoolTag is 3rd arg
    # Senior-dev review MAJ-2: original regex consumed 3 commas before the capture, hitting
    # the 4th arg (BufferSize). Reduced to 2 leading args so we capture the 3rd (PoolTag).
    re.compile(r'\bWdfMemoryCreate\s*\([^)]*?,\s*[^)]*?,\s*([^)]+?)\s*,'),
]

EXPECTED_TAG = "'M12 '"  # four chars: M, 1, 2, space

findings = []
for i, line in enumerate(lines, 1):
    for pat in alloc_patterns:
        m = pat.search(line)
        if m:
            tag_expr = m.group(1).strip()
            # Accept 'M12 ' or the equivalent hex or a named constant that contains M12
            if tag_expr in ("'M12 '", '"M12 "') or 'M12' in tag_expr:
                continue
            findings.append(f"{i}:{tag_expr}")

for f in findings:
    print(f)
PYEOF
)

    if [[ -n "$result" ]]; then
        while IFS= read -r hit; do
            local lineno="${hit%%:*}"
            local tag="${hit#*:}"
            add_violation "$rel_file" "pool-tag" "REJECT" "$lineno" \
                "Pool allocation uses tag '${tag}' instead of required 'M12 '. All M12 driver allocations must carry the project pool tag."
        done <<< "$result"
    fi
}

# ---- CHECK 8: clang-format compliance ----
# Invoke clang-format --dry-run --Werror. Failure => REJECT.
check_clang_format() {
    local file="$1"
    local rel_file="${file#$REPO_ROOT/}"

    if ! command -v clang-format >/dev/null 2>&1; then
        # clang-format not installed — soft WARN, do not block
        add_violation "$rel_file" "clang-format" "WARN" "-" \
            "clang-format not found in PATH. Install clang-format and re-run to validate formatting against WDF preset."
        return
    fi

    local cfg_flag=""
    if [[ -f "$CLANG_FORMAT_CFG" ]]; then
        cfg_flag="--style=file:${CLANG_FORMAT_CFG}"
    else
        # Fallback: inline the WDF preset
        cfg_flag='--style={BasedOnStyle: Microsoft, IndentWidth: 4, ColumnLimit: 100, AllowShortIfStatementsOnASingleLine: false, AllowShortLoopsOnASingleLine: false, DerivePointerAlignment: false, PointerAlignment: Right, SortIncludes: false}'
    fi

    local output
    local exit_code=0
    # shellcheck disable=SC2086
    output=$(clang-format --dry-run --Werror $cfg_flag "$file" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        # Truncate output for readability
        local short_output="${output:0:300}"
        add_violation "$rel_file" "clang-format" "REJECT" "-" \
            "clang-format reports formatting violations. Run: clang-format ${cfg_flag} -i ${rel_file}. Output: ${short_output//
/; }"
    fi
}

# ---- run all checks on each file ----
if [[ ${#TARGET_FILES[@]} -eq 0 ]]; then
    echo "check-style: no .c/.h files found for mode '${MODE}'" >&2
    echo "  (nothing to check -- pass)" >&2
    # Still write empty pass outputs
    python3 - "$RESULTS_JSON" "$RESULTS_MD" "$TIMESTAMP" <<'PYEOF'
import json, sys
results_json, results_md, ts = sys.argv[1], sys.argv[2], sys.argv[3]

summary = {"timestamp": ts, "files_checked": 0, "violations": [], "verdict": "PASS"}
with open(results_json, 'w') as f:
    json.dump(summary, f, indent=2)

with open(results_md, 'w') as f:
    f.write(f"# M12 Style Report\n\n**{ts}** | Files checked: 0 | Verdict: **PASS**\n\nNo .c/.h files in scope.\n")
PYEOF
    exit 0
fi

for f in "${TARGET_FILES[@]}"; do
    echo "check-style: scanning ${f#$REPO_ROOT/} ..."
    check_comment_density "$f"
    check_todo_fixme "$f"
    check_generic_names "$f"
    check_mixed_casing "$f"
    check_defensive_null "$f"
    check_helper_callers "$f"
    check_pool_tags "$f"
    check_clang_format "$f"
done

# ---- produce outputs ----
python3 - "$RESULTS_JSON" "$RESULTS_MD" "$TIMESTAMP" "$HAS_REJECT" "$VIOLATIONS_JSONL" <<'PYEOF'
import json, sys

results_json = sys.argv[1]
results_md = sys.argv[2]
ts = sys.argv[3]
has_reject_str = sys.argv[4]
violations_jsonl = sys.argv[5]
has_reject = has_reject_str == 'true'

violations = []
try:
    with open(violations_jsonl, 'r') as f:
        for line in f:
            line = line.strip()
            if line:
                violations.append(json.loads(line))
except FileNotFoundError:
    violations = []
except Exception:
    violations = []

verdict = "FAIL" if has_reject else "PASS"

# Count by severity
rejects = [v for v in violations if v['severity'] == 'REJECT']
flags   = [v for v in violations if v['severity'] == 'FLAG']
warns   = [v for v in violations if v['severity'] == 'WARN']

# ---- JSON output ----
summary = {
    "timestamp": ts,
    "files_checked": len(set(v['file'] for v in violations)) if violations else 0,
    "verdict": verdict,
    "counts": {
        "REJECT": len(rejects),
        "FLAG": len(flags),
        "WARN": len(warns),
        "total": len(violations)
    },
    "violations": violations
}
with open(results_json, 'w') as f:
    json.dump(summary, f, indent=2)

# ---- Markdown output ----
verdict_badge = "FAIL -- commit blocked" if has_reject else "PASS"
lines = [
    "# M12 Style-Guide Report",
    "",
    f"**Generated:** {ts}  ",
    f"**Verdict:** **{verdict_badge}**  ",
    f"**Violations:** {len(rejects)} REJECT / {len(flags)} FLAG / {len(warns)} WARN",
    "",
]

if rejects:
    lines += ["## Hard failures (REJECT -- must fix before commit/PR)", ""]
    for v in rejects:
        lines.append(f"- **[{v['check']}]** \`{v['file']}\` line {v['line']}: {v['detail']}")
    lines.append("")

if flags:
    lines += ["## Soft flags (FLAG -- review required)", ""]
    for v in flags:
        lines.append(f"- **[{v['check']}]** \`{v['file']}\` line {v['line']}: {v['detail']}")
    lines.append("")

if warns:
    lines += ["## Advisory warnings (WARN -- informational)", ""]
    for v in warns:
        lines.append(f"- **[{v['check']}]** \`{v['file']}\` line {v['line']}: {v['detail']}")
    lines.append("")

if not violations:
    lines += ["## All checks passed", "", "No violations detected."]

lines += [
    "",
    "---",
    "<!-- Generated by scripts/check-style.sh -->",
]

with open(results_md, 'w') as f:
    f.write('\n'.join(lines) + '\n')

print(f"check-style: verdict={verdict} | REJECT={len(rejects)} FLAG={len(flags)} WARN={len(warns)}")
print(f"  -> {results_json}")
print(f"  -> {results_md}")
PYEOF

# ---- exit code ----
if [[ "$HAS_REJECT" == "true" ]]; then
    echo "check-style: FAIL -- one or more REJECT violations found. See style-report.md." >&2
    exit 1
fi

echo "check-style: PASS"
exit 0
