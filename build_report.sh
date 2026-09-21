#!/usr/bin/env bash
# build_report.sh - turn group files (1.txt, 2.txt, ...) into one CSV report.
#
# Each input file is named <group number>.txt and looks like example.txt:
#
#   [members]
#   one member per line: roll number and name, in either order,
#   separated by commas, spaces, tabs, pipes, dashes - anything goes
#
#   [topic]
#   topic name
#
#   [github]
#   GitHub link
#
# Member lines: the roll number is the first word containing a digit;
# everything else on the line is the name. All of these are equivalent:
#   101, Abhinav S      Abhinav S, 101      101 Abhinav S
#   Abhinav S 101       101 - Abhinav S     Abhinav S | 101
#
# Output CSV columns: group,roll_no,name,topic,link
# The group's topic and link are repeated on every member's row.
#
# Usage:
#   ./build_report.sh [-c] [-o output.csv] [input_dir]
#
#   -c   also check each GitHub repo exists using the GitHub CLI (gh repo view).
#        Problems are reported as warnings; the CSV content is not changed.
#   -o   output file (default: report.csv). Use a name ending in .xlsx to get an
#        Excel file instead; that needs python3 with openpyxl and csv_to_xlsx.py
#        placed next to this script.
#   input_dir defaults to the current directory.

set -euo pipefail

CHECK=0
OUT="report.csv"

while getopts ":co:" opt; do
  case "$opt" in
    c) CHECK=1 ;;
    o) OUT="$OPTARG" ;;
    *) echo "Usage: $0 [-c] [-o output.csv] [input_dir]" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
DIR="${1:-.}"

# For .xlsx output, build a temporary CSV first and convert it at the end.
CSV="$OUT"
if [[ "${OUT,,}" == *.xlsx ]]; then
  CONVERTER="$(dirname "${BASH_SOURCE[0]}")/csv_to_xlsx.py"
  [[ -f "$CONVERTER" ]] || { echo "csv_to_xlsx.py not found next to this script" >&2; exit 1; }
  python3 -c "import openpyxl" 2>/dev/null || { echo "openpyxl not installed (pip install openpyxl)" >&2; exit 1; }
  CSV="$(mktemp --suffix=.csv)"
  trap 'rm -f "$CSV"' EXIT
fi

if [[ $CHECK -eq 1 ]]; then
  command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) not found" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first" >&2; exit 1; }
fi

# Warnings go to stderr; on GitHub Actions they also show up as annotations.
warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning::$1" >&2
  else
    echo "WARN $1" >&2
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Split a member line into a roll number and a name, in either order.
# Sets PARSED_ROLL and PARSED_NAME.
parse_member() {
  local raw="${1//[,;|]/ }" tok
  local -a toks name=()
  PARSED_ROLL=""
  read -ra toks <<<"$raw"          # splits on any whitespace, tabs included
  for tok in "${toks[@]}"; do
    [[ "$tok" =~ ^[[:punct:]]+$ ]] && continue   # drop stray "-", "|", ":" etc.
    if [[ -z "$PARSED_ROLL" && "$tok" == *[0-9]* ]]; then
      PARSED_ROLL="$(sed -E 's/^[^[:alnum:]]+//; s/[^[:alnum:]]+$//' <<<"$tok")"
    else
      name+=("$tok")
    fi
  done
  PARSED_NAME="${name[*]:-}"
}

csv_escape() {
  local s="${1//\"/\"\"}"
  printf '"%s"' "$s"
}

# Extract owner/repo from any github.com URL (handles .git, /issues/..., trailing paths)
repo_slug() {
  sed -E 's#^https?://(www\.)?github\.com/([^/]+)/([^/#?]+).*#\2/\3#; s#\.git$##' <<<"$1"
}

echo "group,roll_no,name,topic,link" > "$CSV"

shopt -s nullglob
files=$(find "$DIR" -maxdepth 1 -type f -name '[0-9]*.txt' | sort -V)

if [[ -z "$files" ]]; then
  echo "No files like 1.txt found in $DIR" >&2
  exit 1
fi

rows=0
while IFS= read -r file; do
  group="$(basename "$file" .txt)"
  section=""
  members=()
  topic=""
  link=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # strip Windows line endings
    line="${line#"${line%%[![:space:]]*}"}"    # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"    # trim trailing whitespace
    [[ -z "$line" ]] && continue

    case "${line,,}" in
      "[members]") section="members"; continue ;;
      "[topic]")   section="topic";   continue ;;
      "[github]")  section="github";  continue ;;
    esac

    case "$section" in
      members) members+=("$line") ;;
      topic)   topic="$line" ;;
      github)  link="$line" ;;
    esac
  done < "$file"

  [[ ${#members[@]} -eq 0 ]] && warn "[$group]: no members"
  [[ -z "$topic" ]]          && warn "[$group]: no topic"
  [[ -z "$link" ]]           && warn "[$group]: no GitHub link"

  if [[ $CHECK -eq 1 && -n "$link" ]]; then
    slug="$(repo_slug "$link")"
    if ! gh repo view "$slug" >/dev/null 2>&1; then
      warn "[$group]: repo not found or not accessible: $link (tried $slug)"
    fi
  fi

  for entry in "${members[@]}"; do
    parse_member "$entry"
    roll="$PARSED_ROLL"
    name="$PARSED_NAME"
    [[ -z "$roll" ]] && warn "[$group]: no roll number found in line: $entry"
    [[ -z "$name" ]] && warn "[$group]: no name found for roll number $roll"
    {
      printf '%s,' "$group"
      csv_escape "$roll"; printf ','
      csv_escape "$name"; printf ','
      csv_escape "$topic"; printf ','
      csv_escape "$link"; printf '\n'
    } >> "$CSV"
    rows=$((rows + 1))
  done
done <<<"$files"

if [[ "$CSV" != "$OUT" ]]; then
  python3 "$CONVERTER" "$CSV" "$OUT"
fi

echo "Wrote $rows rows to $OUT"