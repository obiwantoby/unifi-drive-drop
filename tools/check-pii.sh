#!/usr/bin/env bash
# Guard the thing the identity scrub missed: published captures and hardware identifiers.
#
# Why this exists: `main` was scrubbed, the scrubber's own --check reported clean, and the raw
# discovery capture was still public — reachable from the release *tags*, which no branch-scanning
# check ever looks at. Two of the three scans written for this session were also silently broken
# (grepping a concatenated `git cat-file --batch` stream invents matches; `--batch-check` fields are
# oid/type/size, so testing `$1=="blob"` tests nothing). Hence the selftest below: a check that
# cannot be shown to fire is not a check.
#
#   tools/check-pii.sh              audit the repo at HEAD
#   tools/check-pii.sh --selftest   plant leaks in a throwaway repo and prove each rule catches
#                                   its own, and that clean content passes
set -uo pipefail

SKIP_PATHS='tools/redact_capture.py|tools/check-pii.sh'   # must contain examples of what they redact
MAC='([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}'

# --- the rules ------------------------------------------------------------------------------
# Each rule prints "class|location" lines. Values are never printed, so the report is safe to
# paste into a CI log, an issue, or a chat.
rules() {
  # 1. Capture files must not be tracked at all. Redacted or not, they are somebody's console.
  local caps
  caps=$(git ls-files -- 'spec/raw' '*.jsonl' '*/discovery.json' '*/users-me.json' \
                             '*/share-links.json' '*/resources-mydrive*.json' \
                             '*/file-sharing-info.json' '*/drives.json' '*/storage.json' 2>/dev/null \
           | tr '\n' ' ')
  [ -n "$caps" ] && echo "capture files tracked|${caps}"

  # 2. MAC addresses. Locally-administered (bit 1 of the first octet: 02:, 06:, 0a: ... fe:) are
  # synthetic by construction and are what fixtures must use. A universally administered one is a
  # real NIC on somebody's network — this is the class that leaked.
  local f line rest oct
  while IFS=: read -r f line rest; do
    [ -z "$f" ] && continue
    echo "$f" | grep -qE "^($SKIP_PATHS)$" && continue
    oct=$(git show "HEAD:$f" 2>/dev/null | sed -n "${line}p" | grep -oiE "$MAC" | head -1 | cut -c1-2)
    [ -z "$oct" ] && continue
    [ $((16#$oct & 2)) -eq 2 ] && continue
    echo "real (universally administered) MAC address|$f:$line"
  done < <(git grep -nIE "$MAC" -- . 2>/dev/null)

  # 3. Credential material: private keys and JWTs.
  local pat
  for pat in '-----BEGIN [A-Z ]*PRIVATE KEY-----' 'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}'; do
    while IFS=: read -r f line rest; do
      [ -z "$f" ] && continue
      echo "$f" | grep -qE "^($SKIP_PATHS)$" && continue
      echo "credential-shaped literal|$f:$line"
    done < <(git grep -nIE "$pat" -- . 2>/dev/null)
  done

  # 4. Mailboxes that are not an example address.
  local addr
  while IFS=: read -r f line rest; do
    [ -z "$f" ] && continue
    echo "$f" | grep -qE "^($SKIP_PATHS)$" && continue
    addr=$(git show "HEAD:$f" 2>/dev/null | sed -n "${line}p" \
           | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | head -1)
    [ -z "$addr" ] && continue
    case "$addr" in
      *@example.com|*@example.org|*@example.net|*@demo.invalid|*@localhost|*.test) ;;
      *) echo "mailbox that is not an example address|$f:$line" ;;
    esac
  done < <(git grep -nIE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -- . 2>/dev/null)

  # 5. Someone's home directory.
  while IFS=: read -r f line rest; do
    [ -z "$f" ] && continue
    echo "personal Windows path|$f:$line"
  done < <(git grep -nIE '[Cc]:[\\/]+[Uu]sers[\\/]+[A-Za-z0-9._-]+' -- . 2>/dev/null)
}

run_audit() {
  local out
  out=$(rules)
  if [ -z "$out" ]; then echo "check-pii: clean"; return 0; fi
  while IFS='|' read -r cls loc; do
    [ -z "$cls" ] && continue
    printf 'LEAK  %s\n      %s\n' "$cls" "$loc"
  done <<< "$out"
  echo
  echo "check-pii: values withheld on purpose - this output must be safe to paste anywhere."
  return 1
}

# --- selftest -------------------------------------------------------------------------------
selftest() {
  local tmp rc=0
  tmp=$(mktemp -d) || return 2
  # git needs an identity and a default branch, and this repo must never touch the real one.
  git -C "$tmp" init -q -b selftest >/dev/null 2>&1 || git -C "$tmp" init -q >/dev/null 2>&1
  git -C "$tmp" config user.email t@t.invalid
  git -C "$tmp" config user.name t
  git -C "$tmp" config core.autocrlf false      # otherwise every add spams CRLF warnings
  git -C "$tmp" config core.safecrlf false

  check() { # expectation, label
    local want=$1 label=$2 have
    have=$(cd "$tmp" && rules | grep -c "$label")
    if [ "$want" = "hit" ] && [ "$have" -eq 0 ]; then
      echo "  FAIL  rule for [$label] did not fire"; rc=1
    elif [ "$want" = "miss" ] && [ "$have" -ne 0 ]; then
      echo "  FAIL  rule for [$label] fired on clean content"; rc=1
    else
      echo "  ok    [$label] ${want}"
    fi
  }

  echo "selftest: clean content must pass"
  mkdir -p "$tmp/spec/api" "$tmp/apps"
  printf 'curl https://203.0.113.10/api\nmac 02:11:22:33:44:55\nuser@example.com\n' > "$tmp/spec/api/doc.md"
  printf 'checksum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"\n' > "$tmp/Cargo.lock"
  (cd "$tmp" && git add -A >/dev/null && git commit -qm clean >/dev/null)
  check miss 'MAC address'
  check miss 'mailbox'
  check miss 'capture files'

  echo "selftest: each leak must be caught"
  printf 'console nic d8:b3:70:11:22:33\n' > "$tmp/apps/leak.md"                       # universal OUI
  printf 'mail me at real.person@company.example.org\n' > "$tmp/apps/mail.md"          # not an example domain… but is
  printf 'mail me at someone@corp.internal\n' > "$tmp/apps/mail2.md"
  printf 'C:\\Users\\someone\\file\n' > "$tmp/apps/path.md"
  mkdir -p "$tmp/spec/raw"; printf '{"mac":"d8:b3:70:11:22:33"}' > "$tmp/spec/raw/discovery.json"
  printf 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghij\n' > "$tmp/apps/jwt.md"
  (cd "$tmp" && git add -A >/dev/null && git commit -qm dirty >/dev/null)
  check hit 'MAC address'
  check hit 'mailbox'
  check hit 'capture files'
  check hit 'credential-shaped'
  check hit 'personal Windows path'

  rm -rf "$tmp"
  [ "$rc" -eq 0 ] && echo "selftest: all rules fire, clean content passes" || echo "selftest: FAILURES above"
  return $rc
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  *) cd "$(dirname "$0")/.." || exit 2; run_audit; exit $? ;;
esac
