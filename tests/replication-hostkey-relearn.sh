#!/usr/bin/env bash
# replication-hostkey-relearn.sh [built-system] — OFF-BOX test of the backup sender's behaviour when
# the backup box's SSH host key or Tailscale node key changes (found on a real pair, 2026-10-05).
#
# It cuts the preflight/push/record/classify code OUT OF THE BUILT cloudunit-replica-sync script (not
# a copy of it), points its tools at this machine's own, and runs it against a throwaway sshd on
# 127.0.0.1 whose host key is replaced between runs. `tailscale whois`, `ip route get` and the logger
# are stubs the test controls. Nothing outside a temp folder is touched.
#
# NOT covered here: the rest of the script (address lookup, the media loop, the status file), the
# real receiver's forced command, real Tailscale, base.nix, factory reset, unpair, the backup page,
# and anything on a Pi. Those are the hardware gate.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOP="$(readlink -f "${1:-$REPO/result-hostkey-prod-top}")"
SYNC="$(nix-store -qR "$TOP" | grep -E 'cloudunit-replica-sync$' | head -1)/bin/cloudunit-replica-sync"
[ -f "$SYNC" ] || { echo "no built cloudunit-replica-sync under $TOP"; exit 2; }
# OpenSSH from the SAME nixpkgs the image is built from (flake.nix does the same for its VM test).
OPENSSH="$(nix build --impure --no-link --print-out-paths --expr "(builtins.getFlake \"$REPO\").inputs.nixos-raspberrypi.inputs.nixpkgs.legacyPackages.x86_64-linux.openssh" 2>/dev/null | tail -1)"
[ -x "$OPENSSH/bin/sshd" ] || { echo "no native sshd for the test"; exit 2; }
for t in rsync jq; do command -v $t >/dev/null || { echo "missing $t"; exit 2; }; done
REAL_RSYNC="$(command -v rsync)"

W="$(mktemp -d)"; PORT=$(( 20000 + RANDOM % 20000 )); PASS=0; FAIL=0
cleanup() { [ -f "$W/sshd.pid" ] && kill "$(cat "$W/sshd.pid")" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
ok()  { PASS=$((PASS+1)); echo "  PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $*"; }

mkdir -p "$W/repl/dump" "$W/landing" "$W/bin"
echo "dump-1" > "$W/repl/dump/immich-1.sql.zst"
"$OPENSSH/bin/ssh-keygen" -q -t ed25519 -N "" -f "$W/repl/pair_key"
cp "$W/repl/pair_key.pub" "$W/authorized_keys"
# ---- stubs --------------------------------------------------------------------------------------
cat > "$W/bin/tailscale" <<EOF
#!/bin/sh
[ "\$1" = "whois" ] || exit 0
[ -s $W/whois-id ] || exit 1          # Tailscale has no answer
printf '{"Node":{"StableID":"%s","Key":"%s"}}\n' "\$(cat $W/whois-id)" "\$(cat $W/whois-key)"
EOF
cat > "$W/bin/ip" <<EOF
#!/bin/sh
echo "\$4 dev \$(cat $W/route-dev) table 52 src 100.64.0.1 uid 0 \\\\    cache "
EOF
cat > "$W/bin/logger" <<EOF
#!/bin/sh
shift 2; echo "\$*" >> $W/log
EOF
# rsync wrapper: real rsync, except that invocation number \$(cat fail-on) fails like a dropped link
cat > "$W/bin/rsync" <<EOF
#!/bin/sh
n=\$(( \$(cat $W/rsync-count 2>/dev/null || echo 0) + 1 )); echo \$n > $W/rsync-count
if [ "\$(cat $W/fail-on 2>/dev/null)" = "\$n" ]; then echo "ssh: connect to host 127.0.0.1 port $PORT: Connection refused" >&2; exit 255; fi
exec $REAL_RSYNC "\$@"
EOF
chmod +x "$W/bin/"*; : > "$W/log"

server() {   # (re)start the fake backup box with a NEW host key; prints the new fingerprint
  if [ -f "$W/sshd.pid" ]; then P="$(cat "$W/sshd.pid")"; kill "$P" 2>/dev/null; while kill -0 "$P" 2>/dev/null; do sleep 0.1; done; rm -f "$W/sshd.pid"; fi
  rm -f "$W/hostkey" "$W/hostkey.pub"; "$OPENSSH/bin/ssh-keygen" -q -t ed25519 -N "" -f "$W/hostkey"
  cat > "$W/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $W/hostkey
PidFile $W/sshd.pid
AuthorizedKeysFile $W/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
# Like the real backup box, every login is forced into one landing folder; without this
# rsync's "." would be the tester's home directory.
ForceCommand cd $W/landing && eval "\$SSH_ORIGINAL_COMMAND"
EOF
  "$OPENSSH/bin/sshd" -f "$W/sshd_config" -E "$W/sshd.log" || { echo "sshd did not start"; cat "$W/sshd.log"; exit 2; }
  for i in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.1; done
  "$OPENSSH/bin/ssh-keygen" -lf "$W/hostkey.pub" | awk '{print $2}'
}

# ---- the code under test, cut from the built script --------------------------------------------
{
  sed -n '/^[[:space:]]*classify() {/,/^[[:space:]]*}$/p' "$SYNC"
  sed -n '/The host key is filed under/,/---- 1\. DUMP FIRST/p' "$SYNC"
} | sed -E \
    -e "s#/nix/store/[a-z0-9]{32}-openssh-[^/]+/bin/#$OPENSSH/bin/#g" \
    -e "s#/nix/store/[a-z0-9]{32}-rsync-[^/]+/bin/rsync#$W/bin/rsync#g" \
    -e "s#/nix/store/[a-z0-9]{32}-tailscale-[^/]+/bin/tailscale#$W/bin/tailscale#g" \
    -e "s#/nix/store/[a-z0-9]{32}-iproute2-[^/]+/bin/ip#$W/bin/ip#g" \
    -e "s#/nix/store/[a-z0-9]{32}-jq-[^/]+/bin/jq#$(command -v jq)#g" \
    -e "s#/nix/store/[a-z0-9]{32}-(coreutils|gnused|gnugrep|gawk)-[^/]+/bin/#/usr/bin/#g" \
    -e "s#/var/lib/cloudunit/replication#$W/repl#g" \
    -e "s#kh-replica@#$USER@#g" > "$W/under-test.sh"
for f in "push()" "classify()" "preflight()" "record_node_key()" "may_relearn()"; do grep -q "$f" "$W/under-test.sh" || { echo "could not cut $f from $SYNC"; exit 2; }; done
LEFT="$(grep -o "/nix/store/[^ \"]*" "$W/under-test.sh" | grep -v "^$OPENSSH/" | sort -u)"
[ -z "$LEFT" ] || { echo "unmapped store path left in the code under test:"; echo "$LEFT"; exit 2; }

run() {   # run <whois-id> [node-key] [route-device] : one "nightly run" in a fresh shell, as the real
          # script does it: preflight, first push, record_node_key. SECOND=1 adds a second push.
  printf '%s' "$1" > "$W/whois-id"; printf '%s' "${2:-nodekey:AAA}" > "$W/whois-key"; echo "${3:-tailscale0}" > "$W/route-dev"
  echo 0 > "$W/rsync-count"
  ( set -u; co=/usr/bin; LOGGER="$W/bin/logger"; IP=127.0.0.1; NODEID="nPAIRED123CNTRL"; CSTATE=""; CMSG=""
    status() { echo "RESULT stopped-before-sending state=$1 msg=$2"; }      # the real one writes sync-status.json
    . "$W/under-test.sh"                                                     # runs preflight; exits here if it says no
    SSH="$SSH -p $PORT -F /dev/null -o IdentitiesOnly=yes"
    if push "$W/repl/./dump"; then record_node_key; echo "RESULT ok relearned=$RELEARNED"
    else classify "$OUT"; echo "RESULT fail state=$CSTATE relearned=$RELEARNED msg=$CMSG"; fi
    if [ "${SECOND:-}" = 1 ]; then eval "$BETWEEN"; if push "$W/repl/./dump"; then echo "SECOND ok"; else classify "$OUT"; echo "SECOND fail state=$CSTATE"; fi; fi
  ) 2>&1
}
known() { "$OPENSSH/bin/ssh-keygen" -lf "$W/repl/known_hosts" 2>/dev/null | awk '{print $2, $3}' | tr '\n' ';'; }
pin()   { cat "$W/repl/peer_nodekey" 2>/dev/null; }
sent()  { cat "$W/rsync-count"; }
A="$W/repl/host-key-changes.log"

echo "code under test: $SYNC"
echo "test OpenSSH:    $("$OPENSSH/bin/ssh" -V 2>&1)"
echo "== 0. the field failure, reproduced with the OLD options (no recovery)"
server >/dev/null; OLDSSH="$OPENSSH/bin/ssh -i $W/repl/pair_key -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$W/old_known -p $PORT -F /dev/null -o IdentitiesOnly=yes"
$REAL_RSYNC -a -R -e "$OLDSSH" "$W/repl/./dump" "$USER@127.0.0.1:." >/dev/null 2>&1 && ok "first push with a new partner works" || bad "baseline push failed"
server >/dev/null; O="$($REAL_RSYNC -a -R -e "$OLDSSH" "$W/repl/./dump" "$USER@127.0.0.1:." 2>&1)"
echo "$O" | grep -q "Host key verification failed" && ok "after the partner's key changes the OLD sender fails with: Host key verification failed" || bad "old sender did not fail as in the field: $O"

echo "== 1. first run against a partner it has never seen"
K1="$(server)"; R="$(run nPAIRED123CNTRL)"; echo "     $R"
[ "$R" = "RESULT ok relearned=0" ] && ok "pushed; key learned" || bad "$R"
# OpenSSH stores the alias lower-cased; ssh-keygen -R and -F match it either way (tests 2 and 10 rely on that).
known | grep -q -i "keephaven-peer-nPAIRED123CNTRL" && known | grep -q "$K1" && ! known | grep -q "127.0.0.1" && ok "host key remembered under the node id, not the address" || bad "known_hosts: $(known)"
[ -f "$W/landing/dump/immich-1.sql.zst" ] && ok "the file arrived" || bad "file missing on the receiver"
[ "$(pin)" = "nPAIRED123CNTRL nodekey:AAA" ] && [ "$(stat -c %a "$W/repl/peer_nodekey")" = "600" ] && ok "node key recorded after the first push, mode 600" || bad "pin: $(pin)"

echo "== 2. the partner's host key changes (an update), same node, same node key"
K2="$(server)"; echo "dump-2" > "$W/repl/dump/immich-2.sql.zst"; R="$(run nPAIRED123CNTRL)"; echo "     $R"
[ "$R" = "RESULT ok relearned=1" ] && ok "recovered by itself and pushed" || bad "$R"
known | grep -q "$K2" && ! known | grep -q "$K1" && ok "old host key forgotten, new one remembered" || bad "known_hosts: $(known)"
grep -q "host key changed; re-learned it (Tailscale node nPAIRED123CNTRL" "$A" && grep -q "re-learned it" "$W/log" && ok "written to the journal AND to the file that survives updates" || bad "no record of the re-learn"
[ -f "$W/landing/dump/immich-2.sql.zst" ] && ok "the new file arrived" || bad "new file missing"

echo "== 3. next night, nothing changed"
R="$(run nPAIRED123CNTRL)"; [ "$R" = "RESULT ok relearned=0" ] && ok "plain push, no recovery needed" || bad "$R"

echo "== 4. the host key changes TWICE inside one run: only one recovery is allowed"
server >/dev/null; export SECOND=1 BETWEEN='server >/dev/null'; export -f server; export W PORT OPENSSH
R="$(run nPAIRED123CNTRL)"; unset SECOND BETWEEN; echo "     $(echo "$R" | tr '\n' ' ')"
echo "$R" | grep -q "RESULT ok relearned=1" && echo "$R" | grep -q "SECOND fail state=rejected" && ok "second change in the same run is refused" || bad "$R"
R="$(run nPAIRED123CNTRL)"; [ "$R" = "RESULT ok relearned=1" ] || bad "could not settle after test 4: $R"

echo "== 5. Tailscale says the address belongs to a DIFFERENT node"
BEFORE="$(known)"; R="$(run nSOMEONEELSE9CNTRL)"; echo "     $R"
echo "$R" | grep -q "RESULT stopped-before-sending state=rejected msg=couldn't confirm the other box is your backup Keephaven" && [ "$(sent)" = 0 ] && ok "refused before anything was sent; owner told to pair again" || bad "$R (rsync runs: $(sent))"
[ "$(known)" = "$BEFORE" ] && grep -q "refused: 127.0.0.1 answers as Tailscale node nSOMEONEELSE9CNTRL" "$A" && ok "nothing re-learned; recorded" || bad "known_hosts or record wrong"

echo "== 6. Tailscale gives no answer about the address"
R="$(run "")"; echo "     $R"
echo "$R" | grep -q "RESULT stopped-before-sending state=unreachable" && [ "$(sent)" = 0 ] && ok "skipped for tonight as unreachable, NOT 'pair again'" || bad "$R"

echo "== 7. the address would leave by the LAN, not by Tailscale"
R="$(run nPAIRED123CNTRL nodekey:AAA eth0)"; echo "     $R"
echo "$R" | grep -q "RESULT stopped-before-sending state=unreachable" && [ "$(sent)" = 0 ] && ok "nothing sent" || bad "$R"

echo "== 8. host key and node key vouch for each other (verifier's hardening)"
server >/dev/null; BEFORE="$(known)"; R="$(run nPAIRED123CNTRL nodekey:ROGUE)"; echo "     $R"
echo "$R" | grep -q "RESULT fail state=rejected relearned=0" && [ "$(known)" = "$BEFORE" ] && [ "$(pin)" = "nPAIRED123CNTRL nodekey:AAA" ] && ok "host key AND node key both new, same node id -> refused; nothing re-learned, pin kept" || bad "$R | $(known) | $(pin)"
grep -q "refused: the backup box's host key changed and it could not be confirmed" "$A" && ok "recorded" || bad "no record"
R="$(run nPAIRED123CNTRL nodekey:AAA)"; [ "$R" = "RESULT ok relearned=1" ] && ok "host key new, node key the one on file -> re-learned" || bad "$R"
R="$(run nPAIRED123CNTRL nodekey:BBB)"; [ "$R" = "RESULT ok relearned=0" ] && [ "$(pin)" = "nPAIRED123CNTRL nodekey:BBB" ] && grep -q "node key changed (same host key); recorded the new one" "$A" && ok "node key new, host key unchanged -> push ok, new node key recorded" || bad "$R | $(pin)"

echo "== 9. a pair made before this existed (no node key on file)"
rm -f "$W/repl/peer_nodekey"; server >/dev/null; R="$(run nPAIRED123CNTRL nodekey:CCC)"
[ "$R" = "RESULT ok relearned=1" ] && [ "$(pin)" = "nPAIRED123CNTRL nodekey:CCC" ] && ok "node id decides once, host key re-learned, then the node key is recorded" || bad "$R | $(pin)"
echo "nOLDPARTNER9CNTRL nodekey:ZZZ" > "$W/repl/peer_nodekey"; server >/dev/null; R="$(run nPAIRED123CNTRL nodekey:CCC)"
[ "$R" = "RESULT ok relearned=1" ] && [ "$(pin)" = "nPAIRED123CNTRL nodekey:CCC" ] && ok "a node key on file for a DIFFERENT node id is ignored, then replaced" || bad "$R | $(pin)"

echo "== 10. node key on file but NO host key on file (the reviewer's hole)"
rm -f "$W/repl/known_hosts" "$W/repl/known_hosts.old"; server >/dev/null; R="$(run nPAIRED123CNTRL nodekey:ROGUE)"; echo "     $R"
echo "$R" | grep -q "RESULT stopped-before-sending state=rejected" && [ "$(sent)" = 0 ] && [ -z "$(known)" ] && [ "$(pin)" = "nPAIRED123CNTRL nodekey:CCC" ] && ok "new host key + new node key with nothing to vouch -> refused before sending; nothing learned" || bad "$R | $(known) | $(pin)"
R="$(run nPAIRED123CNTRL nodekey:CCC)"; [ "$R" = "RESULT ok relearned=0" ] && ok "same node key vouches -> the host key is learned again (also the case of a sender whose memory was lost)" || bad "$R"

echo "== 11. the retry fails after the old host key was forgotten"
server >/dev/null; echo 2 > "$W/fail-on"; R="$(run nPAIRED123CNTRL nodekey:CCC)"; rm -f "$W/fail-on"; echo "     $R"
echo "$R" | grep -q "RESULT fail state=unreachable relearned=1" && grep -q "old one was forgotten but the retry failed, nothing learned yet" "$A" && [ -z "$(known)" ] && ok "says so, and does not claim to have re-learned" || bad "$R | $(known)"
R="$(run nPAIRED123CNTRL nodekey:ROGUE2)"; echo "$R" | grep -q "stopped-before-sending state=rejected" && ok "a stranger arriving in that gap is refused" || bad "$R"
R="$(run nPAIRED123CNTRL nodekey:CCC)"; [ "$R" = "RESULT ok relearned=0" ] && ok "the real partner, next night: the node key on file vouches, backup resumes" || bad "$R"

echo "== 12. messages for other failures are unchanged"
c() { ( CSTATE=""; CMSG=""; co=/usr/bin; IP=127.0.0.1; NODEID=nPAIRED123CNTRL; LOGGER="$W/bin/logger"; status() { :; }; printf nPAIRED123CNTRL > "$W/whois-id"; echo tailscale0 > "$W/route-dev"; . "$W/under-test.sh" >/dev/null 2>&1; classify "$1"; echo "$CSTATE"; ); }
[ "$(c 'kex_exchange_identification: read: Connection reset by peer')" = "unreachable" ] && ok "Connection reset -> unreachable" || bad "reset -> $(c 'Connection reset by peer')"
[ "$(c 'user@host: Permission denied (publickey).')" = "rejected" ] && ok "Permission denied -> rejected (pair again)" || bad "denied"
[ "$(c 'keephaven-replication: refused: backup storage is full')" = "full" ] && ok "full -> full" || bad "full"
[ "$(c 'ssh: connect to host 100.1.2.3 port 22: Connection timed out')" = "unreachable" ] && ok "timed out -> unreachable" || bad "timeout"
[ "$(c 'something nobody expected')" = "error" ] && ok "unknown -> generic error" || bad "unknown"

echo; echo "record kept on the data partition during this test ($(wc -l < "$A") lines), last three:"; tail -3 "$A" | cut -c1-170 | sed 's/^/    /'
echo; echo "passed $PASS, failed $FAIL"; [ "$FAIL" = 0 ]
