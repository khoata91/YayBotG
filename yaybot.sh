#!/usr/bin/env bash
# =============================================================================
#  YayBot — supports ONE plugin you choose (e.g. YayExtra) in the Slack channels you name:
#  checks its source code, reads its tickets there; answers Claude can give are posted in the
#  ticket's thread, visible ONLY to you (YayBot writes nowhere else in Slack),
#  classifies them, lets Claude work on them and reports in Claude Remote Control sessions
#  (on your phone). Needs only: bash, curl, jq, tmux, claude (Claude Code).
#
#  yb setup [xoxb-token] [dir]   Step 2: save the token, then asks for the plugin + its channels
#  yb plugin <Name> #ch1 #ch2    Support this plugin, reading tickets from these Slack channels
#                                (#ch:all = every message there is a ticket; a channel named
#                                after the plugin counts as :all automatically)
#  yb channels [#ch1 #ch2]       Change the channels (no names = list all channels and pick)
#  yb plugin                     Show the plugin, its source folder and its channels
#  yb scan  [7|2026-10-01]       Step 3: find the plugin's tickets + classify them (dry run, creates nothing)
#  yb start                      Step 4: open the Claude Remote Control session "YayBot" in the
#                                background; it runs `yb run` every 10 minutes and reports on your phone
#  yb stop [all] | attach        Stop the session (all = also the ticket sessions) / view it on this Mac
#  yb run                        Run once: fetch new tickets → open ONE Claude Remote Control session
#                                per ticket (name "T7 · YayExtra · major · person") → each session
#                                pushes its result to your phone → summary report in "YayBot"
#  yb sessions | close T7|all    List the ticket sessions (working / open / stopped) / close them
#  yb cleanup [-y]               Close finished ticket sessions and remove their git worktrees
#  yb try [days]                 Take the newest ticket now and open its session (quick test)
#  yb autostart [on|off]         Start YayBot again by itself when you log in to the Mac (after a power off)
#  yb boot                       What autostart runs: restart YayBot + resume the unfinished ticket sessions
#  yb device [name]              Show / set this computer's name (in session names, replies and log)
#  yb collect                    Pick up finished ticket sessions now: Slack thread replies + report
#  yb rescan [days]              Read the channels again (e.g. after changing the plugin or keywords)
#  yb slack [you]               Your Slack name: the replies in ticket threads are visible only to you
#  yb doctor                     Show why tickets are not processed / sessions are not on the phone
#  yb ping                       Send a test push notification to your phone
#  yb report                     Print a report now (including tickets still pending)
#  yb status | log               Status / log
#  yb install | manifest         Install the `yb` command / print the Slack app manifest (step 1)
#
#  Temporary data + config: ~/.yaybot (no database). Compatible with bash 3.2 (macOS).
# =============================================================================

YB_HOME="${YAYBOT_HOME:-$HOME/.yaybot}"
CONF="$YB_HOME/config"
STATE="$YB_HOME/state.json"
LOG="$YB_HOME/yaybot.log"
PLUGINS_FILE="$YB_HOME/plugins.json"
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do _l=$(readlink "$_src"); case "$_l" in /*) _src=$_l ;; *) _src="$(dirname "$_src")/$_l" ;; esac; done
SELF="$(cd "$(dirname "$_src")" && pwd)/$(basename "$_src")"

# ---- Defaults (override in ~/.yaybot/config) -------------------------------------
SLACK_BOT_TOKEN=""
PLUGIN=""                                        # the plugin YayBot supports (set by: yb plugin <Name>)
CHANNELS=""                                      # Slack channels to read (you name them: yb plugin <Name> #ch …)
CHANNEL_PLUGINS=""                               # "C123=yayextra": channels only about the plugin — every message is a ticket
MY_SLACK_ID=""                                   # YOUR Slack member ID: drafts in support threads are "Only visible to you"
SLACK_DRAFTS=1                                   # 1 = post Claude's answer in the ticket thread, visible only to you
DOCS_FILE=""                                     # list of documentation links (default: docs.md next to yaybot.sh)
DOCS_BASE="https://docs.yaycommerce.com"         # used when docs.md has no link for the plugin: DOCS_BASE/<plugin>
PLUGIN_DOCS=""                                   # force one docs URL for the plugin (overrides docs.md)
PLUGINS_DIR=""                                   # folder with the plugins' source code (default: the folder that contains YayBot)
DETECT_DAYS=30                                   # how far back yb plugin reads Slack
CLASSIFIER="claude"                              # claude | rules
CLAUDE_MODEL="haiku"                             # model used for classification
AUTO_FIX_TAGS="trivial"                          # types Claude may fix itself + open a PR, when the plugin folder is a git repo
MIN_CONFIDENCE="0.75"                            # below this → "you need to fix"
RC_NAME="YayBot"                                 # name of the Claude Remote Control session
DEVICE=""                                        # name of this computer, shown in sessions + log (default: its host name)
RC_EVERY="10m"                                   # how often that session runs `yb run`
TICKET_SESSIONS=1                                # 1 = one Remote Control session per ticket; 0 = headless (no session)
MAX_SESSIONS=5                                   # at most this many ticket sessions working at the same time
SESSION_TIMEOUT=7200                             # seconds before a ticket session without result → "you need to fix"
KEEP_SESSIONS_HOURS=24                           # finished ticket sessions are closed after this many hours
KEEP_AWAKE=1                                     # 1 = keep the Mac awake while YayBot runs (caffeinate)
WATCH_EVERY=60                                   # seconds between two checks of the main session (auto-restart)
MAX_RESUMES=2                                    # a ticket session that died (power off, crash) is resumed at most this often
LOOKBACK_DAYS=7
CLAUDE_TIMEOUT=900
API_BASE="${YAYBOT_API_BASE:-https://slack.com/api}"
CLAUDE_BIN="${YAYBOT_CLAUDE_BIN:-claude}"

TAGS="how-to trivial technical major fatal"

# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
API_BASE="${YAYBOT_API_BASE:-$API_BASE}"
CLAUDE_BIN="${YAYBOT_CLAUDE_BIN:-$CLAUDE_BIN}"
# Name of this computer (like CW_DEVICE in cw.sh): shown in every session name, thread reply and log line
DEVICE="${YAYBOT_DEVICE:-$DEVICE}"
if [ -z "$DEVICE" ]; then
	DEVICE=$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || hostname 2>/dev/null)
	DEVICE=$(printf '%s' "${DEVICE:-mac}" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-24)
fi
RC_LABEL="$RC_NAME · $DEVICE"                    # main session name in the Claude app, e.g. "YayBot · work-mac"
# old configs: CURRENCY_CHANNELS → YayCurrency
if [ -z "$CHANNEL_PLUGINS" ] && [ -n "$CURRENCY_CHANNELS" ]; then
	for _c in $CURRENCY_CHANNELS; do CHANNEL_PLUGINS="$CHANNEL_PLUGINS $_c=yaycurrency"; done
fi
[ -n "$PLUGINS_DIR" ] || PLUGINS_DIR="$(dirname "$(dirname "$SELF")")"
PLUGINS_DIR="${PLUGINS_DIR/#\~/$HOME}"

# ---- Helpers --------------------------------------------------------------------
c_g=$'\033[32m'; c_r=$'\033[31m'; c_y=$'\033[33m'; c_b=$'\033[1m'; c_0=$'\033[0m'
[ -t 1 ] || { c_g=; c_r=; c_y=; c_b=; c_0=; }
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%s✗ %s%s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }
logf() { mkdir -p "$YB_HOME"; printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$DEVICE" "$*" >> "$LOG"; }

need() {
	command -v jq >/dev/null 2>&1 || {
		if command -v brew >/dev/null 2>&1; then say "Installing jq…"; brew install jq >/dev/null || die "Could not install jq"; else die "jq is required: brew install jq"; fi
	}
	command -v curl >/dev/null 2>&1 || die "curl is required"
}
need_token() { [ -n "$SLACK_BOT_TOKEN" ] || die "No token yet. Run: yb setup xoxb-…"; }

# yyyy-mm-dd | number of days → epoch
to_epoch() {
	case "$1" in
		'') echo $(( $(date +%s) - LOOKBACK_DAYS * 86400 )) ;;
		*-*-*) date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s 2>/dev/null || date -d "$1" +%s ;;
		*) echo $(( $(date +%s) - $1 * 86400 )) ;;
	esac
}

fmt_date() { # epoch format
	date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2"
}

with_timeout() { # seconds cmd…
	local s=$1; shift
	if command -v timeout >/dev/null 2>&1; then timeout "$s" "$@"
	elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$s" "$@"
	else perl -e 'alarm shift; exec @ARGV' "$s" "$@"; fi
}

# ---- Slack Web API --------------------------------------------------------------
# api method key=value … → JSON (prints a readable error when ok=false)
api() {
	local m=$1; shift
	# Safety: YayBot reads Slack and writes ONLY replies in ticket threads that are visible to YOU
	# (chat.postEphemeral to MY_SLACK_ID). Every other write method is blocked.
	case "$m" in
		auth.test|bots.info|users.list|conversations.list|conversations.history|conversations.replies|conversations.info|conversations.join|chat.getPermalink|users.info) ;;
		chat.postEphemeral)
			{ [ -n "$MY_SLACK_ID" ] && printf '%s\n' "$@" | grep -qx "user=$MY_SLACK_ID"; } || { warn "blocked: ephemeral message not addressed to you"; return 1; } ;;
		*) warn "blocked Slack write method: $m"; return 1 ;;
	esac
	local args=() kv out err
	for kv in "$@"; do args+=(--data-urlencode "$kv"); done
	out=$(curl -sS -m 30 -X POST "$API_BASE/$m" -H "Authorization: Bearer $SLACK_BOT_TOKEN" ${args[@]+"${args[@]}"}) || { warn "Slack $m: could not connect"; return 1; }
	if [ "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" != "true" ]; then
		err=$(printf '%s' "$out" | jq -r '.error // "bad_response"' 2>/dev/null)
		case "$err" in
			not_in_channel)    err="$err — type /invite @YayBot in that channel" ;;
			missing_scope)     err="$err — missing scope $(printf '%s' "$out" | jq -r '.needed // ""'); add it and reinstall the app" ;;
			invalid_auth|not_authed) err="$err — wrong token: yb setup xoxb-…" ;;
			channel_not_found) err="$err — wrong channel ID, or the bot cannot see this channel" ;;
			ratelimited)       sleep 5 ;;
		esac
		warn "Slack $m: $err"
		return 1
	fi
	printf '%s' "$out"
}

# Human messages (no bots, no joins…) since $oldest, oldest first, one JSON per line
history() { # channel oldest
	local cursor="" page all="[]"
	while :; do
		page=$(api conversations.history "channel=$1" "oldest=$2" "limit=200" ${cursor:+"cursor=$cursor"}) || return 1
		all=$(jq -c --argjson a "$all" '$a + .messages' <<<"$page")
		cursor=$(jq -r '.response_metadata.next_cursor // ""' <<<"$page")
		[ -n "$cursor" ] || break
	done
	jq -c 'sort_by(.ts)[] | select(.bot_id == null and (.subtype == null or .subtype == "file_share" or .subtype == "thread_broadcast"))' <<<"$all"
}

permalink() { api chat.getPermalink "channel=$1" "message_ts=$2" 2>/dev/null | jq -r '.permalink // empty'; }

channel_name() {
	local n
	n=$(jq -r --arg c "$1" '.names[$c] // empty' "$STATE" 2>/dev/null)
	if [ -z "$n" ]; then
		n=$(api conversations.info "channel=$1" 2>/dev/null | jq -r '.channel.name // empty')
		[ -n "$n" ] && st_update --arg c "$1" --arg n "$n" '.names[$c] = $n'
	fi
	echo "${n:-$1}"
}

# Real name of a Slack user (cached; needs the users:read scope, falls back to the ID)
user_name() {
	local n
	case "$1" in U*|W*) ;; *) echo "$1"; return ;; esac
	n=$(jq -r --arg u "$1" '.names[$u] // empty' "$STATE" 2>/dev/null)
	if [ -z "$n" ]; then
		n=$(api users.info "user=$1" 2>/dev/null | jq -r '.user | (.profile.display_name | select(. != "")) // (.real_name | select(. != "")) // .name // empty')
		[ -n "$n" ] && st_update --arg u "$1" --arg n "$n" '.names[$u] = $n'
	fi
	echo "${n:-$1}"
}

# "#support-guabin · YayCurrency · major · 2026-10-06 10:49 · Anna — “cart shows €0 for guest…”"
ticket_label() { # channel ts user text tag plugin-slug
	printf '#%s · %s · %s · %s · %s — “%s”' "$(channel_name "$1")" "$(plugin_name "$6")" "$5" "$(fmt_date "${2%.*}" '+%Y-%m-%d %H:%M')" "$(user_name "$3")" \
		"$(flat "$4" | sed -E 's#<[^>]*>##g; s#^[[:space:]-]+##; s#[[:space:]]+# #g' | cut -c1-70)…"
}

# ---- Temporary state (~/.yaybot/state.json) ---------------------------------------
st_init() { mkdir -p "$YB_HOME"; chmod 700 "$YB_HOME"; [ -s "$STATE" ] || echo '{"cursor":{},"tickets":{},"seen":{},"names":{},"seq":0,"sessions":{}}' > "$STATE"; }
st_update() { # jq-args… filter
	local tmp; tmp=$(mktemp "$YB_HOME/.st.XXXXXX")
	jq "$@" "$STATE" > "$tmp" && mv "$tmp" "$STATE" || { rm -f "$tmp"; warn "could not write state"; }
}
lock() {
	local i=0
	until mkdir "$YB_HOME/.lock" 2>/dev/null; do
		i=$((i + 1)); [ $i -gt 120 ] && { warn "stale lock, removing it"; rm -rf "$YB_HOME/.lock"; }
		sleep 1
	done
	trap 'rm -rf "$YB_HOME/.lock"' EXIT INT TERM
}

# ---- Plugins: which plugin is a ticket about? --------------------------------------
flat() { printf '%s' "$1" | tr '\n\r\t' '   '; }

need_plugins() {
	if [ -s "$PLUGINS_FILE" ]; then
		[ -n "$CHANNELS" ] || die "No Slack channel set for $PLUGIN yet. Run: yb channels"
		return 0
	fi
	[ -t 0 ] || die "No plugin chosen yet. Type for example: yb plugin YayExtra"
	cmd_plugin || exit 1
	. "$CONF"; PATTERNS=""
}
plugin_name() { [ -n "$1" ] || { echo "?"; return; }; jq -r --arg s "$1" '(.plugins[] | select(.slug == $s) | .name) // $s' "$PLUGINS_FILE" 2>/dev/null | head -1; }
plugin_dir()  { jq -r --arg s "$1" '.plugins[] | select(.slug == $s) | .dir // empty' "$PLUGINS_FILE" 2>/dev/null | head -1; }

# "slug<TAB>regex" lines: first every plugin's names, then every plugin's feature keywords
plugin_patterns() {
	jq -r 'def rx: gsub("(?<c>[.+*?()\\[\\]{}^$|\\\\])"; "\\\(.c)") | gsub("[ _-]+"; "[ _-]?") | gsub("(?<a>[A-Za-z])\\k<a>"; "\(.a){1,2}");
		[.plugins[] | select(.off != true)] as $p
		| ($p[] | [.slug, ([.names[] | rx] | join("|"))]), ($p[] | [.slug, ([.keywords[]? | rx] | join("|"))])
		| select(.[1] != "") | @tsv' "$PLUGINS_FILE"
}
PATTERNS=""
# prints "slug|reason" when the message is about a supported plugin, nothing otherwise
plugin_match() { # channel text
	local p kw m t pair
	for pair in $CHANNEL_PLUGINS; do
		[ "${pair%%=*}" = "$1" ] && { echo "${pair#*=}|channel"; return; }
	done
	[ -n "$PATTERNS" ] || PATTERNS=$(plugin_patterns)
	t=$(flat "$2" | sed -E 's#<https?://[^>|]*\|?([^>]*)>#\1#g')
	while IFS=$'\t' read -r p kw; do
		[ -n "$kw" ] || continue
		m=$(printf '%s' "$t" | grep -ioE "$kw" | head -1)
		[ -n "$m" ] && { echo "$p|keyword \"$m\""; return; }
	done <<<"$PATTERNS"
}

# Keyword rules → "tag|reason"
classify_rules() { # text
	local t m; t=$(flat "$1")
	m=$(printf '%s' "$t" | grep -ioE 'fatal error|white screen|wsod|site (is )?down|500 error|critical error|cannot access (wp-)?admin' | head -1)
	[ -n "$m" ] && { echo "fatal|$m"; return; }
	m=$(printf '%s' "$t" | grep -ioE '(checkout|payment|order).{0,60}(fail|broken|not work|error)|(wrong|incorrect) (price|total|amount|conversion|rate)|(cart|checkout).{0,120}(€ ?0([^0-9.,]|$)|\$ ?0([^0-9.,]|$)|wrong|incorrect|instead of|switch(es|ing)? between)|instead of [$€£]|payment in [a-z]{3},? not [a-z]{3}|crash|data loss' | head -1)
	[ -n "$m" ] && { echo "major|$m"; return; }
	m=$(printf '%s' "$t" | grep -ioE 'conflict|compatib|php [0-9]|deprecated|hook|ajax|cache|cdn|wpml|polylang|geo ?ip|cron|not updat|(supposed to|should|expected|according to (your|the) doc).{0,80}(but|however|why|instead)' | head -1)
	[ -n "$m" ] && { echo "technical|$m"; return; }
	m=$(printf '%s' "$t" | grep -ioE 'typo|misspell|wrong (label|text|color)|css|alignment|spacing|translation|font|symbol position' | head -1)
	[ -n "$m" ] && { echo "trivial|$m"; return; }
	m=$(printf '%s' "$t" | grep -ioE 'how (do|can|to)|is it possible|where (is|can)|can i' | head -1)
	[ -n "$m" ] && { echo "how-to|$m"; return; }
	echo "technical|no rule matched"
}

# Use Claude (small model) when available; fall back to keyword rules on any error
classify() { # text [plugin-name] → "tag|reason"
	if [ "$CLASSIFIER" = "claude" ] && command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
		local out tag why
		out=$(printf 'YAYBOT_CLASSIFY\nClassify this support ticket for the WordPress plugin %s into exactly one type:\n- how-to: a usage/configuration question, nothing is broken\n- trivial: a small display issue (text, CSS, translation, label/symbol position)\n- technical: conflict/environment issue or behaviour that differs from the docs (plugin, theme, cache, API, settings not applied)\n- major: a core feature or the money flow is wrong or broken (wrong price/total/currency/discount/extra option in cart, checkout or order; payment fails; data lost)\n- fatal: the site or wp-admin is down (white screen, fatal error, 500)\n\nTicket:\n<<<\n%s\n>>>\n\nAnswer with JSON only: {"tag":"…","reason":"short reason in English"}' "${2:-WooCommerce}" "$1" \
			| with_timeout 90 "$CLAUDE_BIN" -p --output-format json --model "$CLAUDE_MODEL" --max-turns 1 2>/dev/null)
		tag=$(jq -r '.result | (try fromjson catch (capture("(?<j>\\{[^{}]*\\})").j | fromjson)) | .tag // empty' <<<"$out" 2>/dev/null)
		why=$(jq -r '.result | (try fromjson catch (capture("(?<j>\\{[^{}]*\\})").j | fromjson)) | .reason // ""' <<<"$out" 2>/dev/null)
		case " $TAGS " in *" $tag "*) [ -n "$tag" ] && { echo "$tag|claude: ${why:-—}"; return; } ;; esac
	fi
	classify_rules "$1"
}

# ---- Commands ---------------------------------------------------------------------
cmd_setup() {
	need; st_init
	local tok="${1:-$SLACK_BOT_TOKEN}"
	if [ -z "$tok" ] && [ -t 0 ]; then printf 'Paste the Bot User OAuth Token (xoxb-…): '; read -rs tok; echo; fi
	case "$tok" in xoxb-*) ;; *) die "The token must start with xoxb- (see step 1 in the README)";; esac
	SLACK_BOT_TOKEN=$tok
	[ -n "$2" ] && PLUGINS_DIR="${2/#\~/$HOME}"

	cat > "$CONF" <<EOF
# YayBot config — edit directly or run again: yb setup
SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN"
CHANNELS="$CHANNELS"
PLUGIN="$PLUGIN"
CHANNEL_PLUGINS="$CHANNEL_PLUGINS"
MY_SLACK_ID="$MY_SLACK_ID"
PLUGINS_DIR="$PLUGINS_DIR"
CLASSIFIER="$CLASSIFIER"
CLAUDE_MODEL="$CLAUDE_MODEL"
AUTO_FIX_TAGS="$AUTO_FIX_TAGS"
MIN_CONFIDENCE="$MIN_CONFIDENCE"
RC_NAME="$RC_NAME"
DEVICE="$DEVICE"
RC_EVERY="$RC_EVERY"
TICKET_SESSIONS=$TICKET_SESSIONS
MAX_SESSIONS=$MAX_SESSIONS
LOOKBACK_DAYS=$LOOKBACK_DAYS
EOF
	chmod 600 "$CONF"
	ok "Config saved: $CONF"
	verify
	enable_push
	say ""; ( cmd_plugin ) || true
	[ -t 0 ] && { say ""; ( cmd_slack ) || true; }
	if [ -s "$PLUGINS_FILE" ] && [ -n "$(conf_get CHANNELS)" ]; then
		say ""; say "${c_b}Done.${c_0} Next: ${c_b}yb scan${c_0} (see the tickets) → ${c_b}yb start${c_0} (reports on your phone)"
	else
		say ""; say "Next: choose the plugin, e.g. ${c_b}yb plugin YayExtra${c_0} → ${c_b}yb scan${c_0} → ${c_b}yb start${c_0}"
	fi
}

# Which scopes does this token really have? (Slack sends them in the x-oauth-scopes header)
NEEDED_SCOPES="channels:history channels:read channels:join groups:history groups:read users:read chat:write"
check_scopes() { # bot-id
	local have miss="" sc app
	have=$(curl -sS -m 30 -D - -o /dev/null -X POST "$API_BASE/auth.test" -H "Authorization: Bearer $SLACK_BOT_TOKEN" 2>/dev/null \
		| tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes:[[:space:]]*//p' | head -1)
	[ -n "$1" ] && app=$(api bots.info "bot=$1" 2>/dev/null | jq -r '.bot.app_id // empty')
	[ -n "$app" ] && ok "Slack app: $app — settings page: https://api.slack.com/apps/$app/oauth"
	[ -n "$have" ] || { warn "Could not read the token's scopes"; return 0; }
	for sc in $NEEDED_SCOPES; do case ",$have," in *",$sc,"*) ;; *) miss="$miss $sc" ;; esac; done
	if [ -z "$miss" ]; then ok "Token scopes OK ($have)"; return 0; fi
	warn "This token is missing:${miss}  (it has: $have)"
	say "  How to fix — on the page above (check that it is the app with this ID):"
	say "   1. OAuth & Permissions → scroll to ${c_b}Scopes → Bot Token Scopes${c_0} (NOT \"User Token Scopes\") → Add:${miss}"
	say "   2. Scroll up → click ${c_b}Reinstall to Workspace${c_0} (or \"Reinstall your app\" in the yellow banner) → Allow"
	say "      If it says \"Request to install\", a workspace admin must approve it first."
	say "   3. Copy the Bot User OAuth Token (xoxb-…) shown there and run: ${c_b}yb setup xoxb-…${c_0}"
}

# Check the token, read access to every channel, the Claude CLI and tmux
verify() {
	local me ch fails=0
	me=$(api auth.test) || die "The token does not work"
	ok "Bot $(jq -r .user <<<"$me") · workspace $(jq -r .team <<<"$me")"
	check_scopes "$(jq -r '.bot_id // ""' <<<"$me")"
	list_channels
	if [ "$(jq length <<<"$CHLIST")" -gt 0 ]; then ok "Sees $(jq length <<<"$CHLIST") Slack channel(s)${CHLIST_ERR:+ ($CHLIST_ERR)}"
	else warn "Cannot list the Slack channels: ${CHLIST_ERR:-0 channels} — add the scopes channels:read and groups:read, then Reinstall to Workspace"; fi
	for ch in $CHANNELS; do
		api conversations.join "channel=$ch" >/dev/null 2>&1   # the bot must be a member to read (Slack shows one "joined" line)
		if api conversations.history "channel=$ch" "limit=1" >/dev/null; then ok "Can read #$(channel_name "$ch") ($ch)"; else fails=$((fails + 1)); fi
	done
	command -v "$CLAUDE_BIN" >/dev/null 2>&1 && ok "Claude CLI: $(command -v "$CLAUDE_BIN")" || warn "claude command not found — will classify by keywords and cannot work on tickets"
	command -v tmux >/dev/null 2>&1 && ok "tmux is installed" || warn "tmux is missing (needed for yb start): brew install tmux"
	ok "YayBot writes only replies in ticket threads, visible only to you"

	[ -n "$CHANNELS" ] || say "  (no Slack channels yet — you name them next: yb plugin <Name> #channel …)"
	[ $fails -eq 0 ] || die "$fails channel(s) cannot be read — fix them using the hints above, then run again: yb plugin"
}

cmd_check() { need; need_token; st_init; verify; }

# Step 3: list plugin tickets + their plugin and type; writes nothing
cmd_scan() {
	need; need_token; st_init; need_plugins
	local since ch msg ts user text why cls tag n=0 skipped=0 pm plug
	since=$(to_epoch "$1")
	local counts="" pcounts=""
	say "${c_b}$PLUGIN tickets since $(fmt_date "$since" '+%Y-%m-%d')${c_0} (dry run, creates nothing)"
	say ""
	for ch in $CHANNELS; do
		local name; name=$(channel_name "$ch")
		while IFS= read -r msg; do
			ts=$(jq -r .ts <<<"$msg"); user=$(jq -r '.user // "?"' <<<"$msg"); text=$(jq -r '.text // ""' <<<"$msg")
			pm=$(plugin_match "$ch" "$text")
			if [ -z "$pm" ]; then skipped=$((skipped + 1)); continue; fi
			plug=${pm%%|*}; why=${pm#*|}
			cls=$(classify "$text" "$(plugin_name "$plug")"); tag=${cls%%|*}
			n=$((n + 1)); counts="$counts $tag"; pcounts="$pcounts $plug"
			printf '%s%2d. [%s · %s]%s #%s · %s · %s\n' "$c_b" "$n" "$(plugin_name "$plug")" "$tag" "$c_0" "$name" "$(fmt_date "${ts%.*}" '+%Y-%m-%d %H:%M')" "$(user_name "$user")"
			printf '    %s\n' "$(flat "$text" | sed -E 's#<[^>]*>##g; s#^[[:space:]-]+##' | cut -c1-160)"
			printf '    ↳ plugin because of %s · type because %s\n\n' "$why" "${cls#*|}"
		done < <(history "$ch" "$since.000000")
	done
	say "${c_b}Total: $n $PLUGIN ticket(s)${c_0} ($skipped other message(s) skipped)"
	local t line=""; for t in $TAGS; do line="$line${line:+ · }$t $(printf '%s\n' $counts | grep -cx "$t")"; done
	say "  $line"
	return 0
}

# Put new messages into the queue
cmd_listen() {
	local ch msg ts user text why cls key oldest new=0 pm plug
	need_plugins
	for ch in $CHANNELS; do
		oldest=$(jq -r --arg c "$ch" '.cursor[$c] // empty' "$STATE")
		[ -n "$oldest" ] || oldest="$(to_epoch "").000000"
		while IFS= read -r msg; do
			ts=$(jq -r .ts <<<"$msg"); user=$(jq -r '.user // "?"' <<<"$msg"); text=$(jq -r '.text // ""' <<<"$msg")
			key="$ch:$ts"
			st_update --arg c "$ch" --arg t "$ts" '.cursor[$c] = $t'
			[ "$(jq -r --arg k "$key" '(.tickets[$k] // .seen[$k]) != null' "$STATE")" = "true" ] && continue
			pm=$(plugin_match "$ch" "$text")
			[ -n "$pm" ] || continue
			plug=${pm%%|*}; why=${pm#*|}
			cls=$(classify "$text" "$(plugin_name "$plug")")
			st_update --arg k "$key" --arg c "$ch" --arg t "$ts" --arg u "$user" --arg x "$text" --arg tag "${cls%%|*}" --arg r "${cls#*|}" --arg w "$why" --arg p "$plug" \
				'.tickets[$k] = {channel:$c, ts:$t, user:$u, text:$x, plugin:$p, tag:$tag, tag_reason:$r, why:$w, status:"new", at:now}'
			new=$((new + 1))
			logf "new ticket: $(ticket_label "$ch" "$ts" "$user" "$text" "${cls%%|*}" "$plug")"
			say "New ticket: $(ticket_label "$ch" "$ts" "$user" "$text" "${cls%%|*}" "$plug")"
		done < <(history "$ch" "$oldest")
	done
	[ $new -gt 0 ] && say "→ $new new $PLUGIN ticket(s)"
	return 0
}

# Tools Claude may use for a ticket (sets: mode, tools[])
ticket_tools() { # allow_fix plugin-dir worktree [docs-url]
	local web=() d
	for d in $(printf '%s\n' "$4" | grep . | while IFS= read -r u; do docs_domain "$u"; echo; done | sort -u); do web+=("WebFetch(domain:$d)"); done
	[ ${#web[@]} -gt 0 ] || web=(WebFetch)
	if [ "$1" = 1 ]; then
		mode=acceptEdits
		tools=( Read Grep Glob "Edit(/$3/**)" "Bash(git -C $2 worktree add:*)" "Bash(git -C $2 fetch:*)" "Bash(git -C $3:*)" "Bash(gh pr create:*)" "Bash(php -l:*)" "${web[@]}" WebSearch )
	else
		mode=default
		tools=( Read Grep Glob "${web[@]}" WebSearch "Bash(git log:*)" "Bash(git show:*)" "Bash(git blame:*)" )
	fi
}

can_fix() { # tag plugin-dir
	case " $AUTO_FIX_TAGS " in *" $1 "*) ;; *) return 1 ;; esac
	[ -n "$2" ] && git -C "$2" rev-parse --git-dir >/dev/null 2>&1
}

# Documentation links of the plugin (one per line):
#   1) PLUGIN_DOCS if set   2) the links in docs.md on lines that mention the plugin   3) DOCS_BASE/<plugin>
docs_file() { echo "${DOCS_FILE:-$(dirname "$SELF")/docs.md}"; }
plugin_docs() { # plugin-slug
	local f urls name
	[ -n "$PLUGIN_DOCS" ] && { echo "$PLUGIN_DOCS"; return; }
	f=$(docs_file)
	if [ -n "$1" ] && [ -f "$f" ]; then
		name=$(plugin_name "$1")
		urls=$(grep -iE -- "$1|${name:-$1}|$(printf '%s' "$name" | sed -E 's/([a-z])([A-Z])/\1[ _-]?\2/g')" "$f" 2>/dev/null \
			| grep -oE 'https?://[^][ )>"`'"'"'<,]+' | sed 's/[.:;]$//' | awk '!seen[$0]++' | head -20)
		[ -n "$urls" ] && { printf '%s\n' "$urls"; return; }
		# no line about this plugin: the documentation links of the list (Claude follows them to the plugin's guides)
		urls=$(grep -oE 'https?://[^][ )>"`'"'"'<,]+' "$f" | sed 's/[.:;]$//' | grep -iE "docs?[./]|/docs?/|$(docs_domain "$DOCS_BASE")" | awk '!seen[$0]++' | head -10)
	fi
	[ -n "$DOCS_BASE" ] && [ -n "$1" ] && urls=$(printf '%s\n%s' "${DOCS_BASE%/}/$1" "$urls")
	printf '%s\n' "$urls" | grep . | awk '!seen[$0]++'
}
docs_domain() { printf '%s' "$1" | sed -E 's#^https?://([^/]+).*#\1#'; }

# Validate Claude's result JSON and mark the ticket done
apply_result() { # key res allow label
	local key=$1 res=$2 allow=$3 label=$4 outcome conf summary
	[ -n "$res" ] || res='{}'
	jq -e 'type == "object"' <<<"$res" >/dev/null 2>&1 || res='{}'
	outcome=$(jq -r '.outcome // "needs_user"' <<<"$res"); conf=$(jq -r '.confidence // 0' <<<"$res")
	summary=$(jq -r '.summary // ""' <<<"$res")
	if [ -z "$summary" ]; then outcome=needs_user; summary="Claude returned no valid result (see yb log)"; res=$(jq -c --arg s "$summary" '.summary = $s' <<<"$res"); fi
	# "fixed" only counts when fixing was allowed and a PR really exists
	if [ "$outcome" = "fixed" ] && { [ "$allow" = 0 ] || [ -z "$(jq -r '.pr_url // ""' <<<"$res")" ]; }; then
		outcome=needs_user; res=$(jq -c '.note = "no PR yet — needs a human fix"' <<<"$res")
	fi
	if [ "$outcome" != "needs_user" ] && awk "BEGIN{exit !($conf < $MIN_CONFIDENCE)}"; then
		outcome=needs_user; res=$(jq -c --arg m "$MIN_CONFIDENCE" '.note = "confidence below " + $m' <<<"$res")
	fi
	st_update --arg k "$key" --arg o "$outcome" --argjson r "$res" '.tickets[$k] += {status:"done", outcome:$o, result:$r, done_at:now}'
	logf "done: $label → $outcome ($conf)"
	say "  → $outcome (confidence $conf): $summary"
	# The result goes into the ticket's thread, visible ONLY to you:
	#   handled → Claude's answer to send;  not handled → what you need to fix (nothing is fixed or answered for you)
	slack_draft "$key"
	return 0
}

# Post Claude's answer under the ticket in Slack as "Only visible to you" (chat.postEphemeral)
slack_draft() { # key
	[ "$SLACK_DRAFTS" = 1 ] || return 0
	[ -n "$MY_SLACK_ID" ] || { warn "No Slack member ID set — the private draft was NOT posted. Run: yb slack"; return 0; }
	local t ch ts txt
	t=$(jq -c --arg k "$1" '.tickets[$k]' "$STATE"); ch=$(jq -r .channel <<<"$t"); ts=$(jq -r .ts <<<"$t")
	txt=$(jq -r 'def one: gsub("\\s+"; " ");
		if .outcome == "needs_user" then
			"🧑‍💻 *YayBot \(.id // "")* · `\(.tag)` · *needs you* · only you can see this\n"
			+ (.result.summary // "" | one)
			+ (if (.result.root_cause // "") != "" then "\n*Cause:* " + (.result.root_cause | one) else "" end)
			+ (if (.result.fix_plan // "") != "" then "\n*Suggested fix:* " + (.result.fix_plan | one) else "" end)
			+ (if (.result.note // "") != "" then "\n_(" + .result.note + ")_" else "" end)
		else
			"✅ *YayBot \(.id // "")* · `\(.tag)` · only you can see this\n"
			+ (if (.result.reply // "") != "" then "*Suggested reply:*\n" + .result.reply else "*Result:* " + (.result.summary // "") end)
			+ (if (.result.pr_url // "") != "" then "\n*PR:* " + .result.pr_url else "" end)
		end' <<<"$t")
	if api chat.postEphemeral "channel=$ch" "user=$MY_SLACK_ID" "thread_ts=$ts" "text=$txt" >/dev/null; then
		say "  → reply posted in the ticket thread in #$(channel_name "$ch") (only you can see it)"; logf "thread reply for $1 posted"
		st_update --arg k "$1" '.tickets[$k].draft = true'
	else
		warn "Could not post the private draft in #$(channel_name "$ch") (you and YayBot must both be members; scope chat:write)"
	fi
}


# Claude works on every "new" ticket
cmd_work() {
	if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then warn "No claude CLI — skipping the work step"; return 0; fi
	if [ "$TICKET_SESSIONS" = 1 ] && command -v tmux >/dev/null 2>&1; then work_sessions; else work_headless; fi
}

# ---- Mode 1 (default): one Claude Remote Control session per ticket -----------------
sess_alive() { tmux has-session -t "=yb-$1" 2>/dev/null; }
pane_tail() { tmux capture-pane -p -t "$1" -S -"${2:-15}" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n "${2:-15}"; }
# Run claude inside tmux; if it stops, keep the window open with the reason (so we can see why)
KEEP='"$@"; c=$?; echo; echo "[yaybot] claude exited (code $c)"; sleep 86400'
# Mark ~/.yaybot as a trusted folder for Claude Code, so a new session does not stop at
# "Do you trust the files in this folder?" (nobody is there to answer it)
trust_dir() {
	local f="$HOME/.claude.json" d tmp
	d=$(cd "$1" 2>/dev/null && pwd -P) || return 0
	[ -f "$f" ] || echo '{}' > "$f"
	[ "$(jq -r --arg d "$d" '.projects[$d].hasTrustDialogAccepted // false' "$f" 2>/dev/null)" = true ] && return 0
	tmp=$(mktemp) && jq --arg d "$d" '.projects[$d] = ((.projects[$d] // {}) + {hasTrustDialogAccepted: true})' "$f" > "$tmp" 2>/dev/null \
		&& [ -s "$tmp" ] && cp "$f" "$f.bak-yaybot" && cat "$tmp" > "$f" && logf "trusted folder $d for Claude Code"
	rm -f "$tmp"
}
# Is claude still running in this tmux session? (the pane's shell keeps a child while it runs)
claude_alive() { # tmux-session
	local pid; pid=$(tmux display -p -t "$1" '#{pane_pid}' 2>/dev/null) || return 1
	[ -n "$pid" ] && pgrep -P "$pid" >/dev/null 2>&1 && [ "$(sess_state "$1" | cut -c1-6)" != exited ]
}
# IDs of tickets still being worked on
active_ids() { jq -r '.tickets[] | select(.status == "session") | .id // empty' "$STATE" 2>/dev/null; }
# Remove a ticket's git worktree (~/.yaybot/worktrees/T7) — never forced: a worktree with unsaved changes is kept
remove_worktree() { # dir
	local wt=$1 common main
	[ -d "$wt" ] || return 0
	common=$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
	if [ -n "$common" ]; then
		main=${common%/.git}
		if git -C "$main" worktree remove "$wt" 2>/dev/null; then git -C "$main" worktree prune 2>/dev/null; logf "removed worktree $wt"; return 0; fi
		warn "Kept $wt: it has changes that are not committed (remove it yourself when done)"; return 1
	fi
	rmdir "$wt" 2>/dev/null; return 0
}

# What is a fresh session showing? → "ok" | "trust" | "exited: …" | "starting"
sess_state() {
	local t; t=$(pane_tail "$1" 30)
	case "$t" in
		*"[yaybot] claude exited"*) echo "exited: $(printf '%s\n' "$t" | grep -v '^\[yaybot\]' | tail -3 | tr '\n' ' ')" ;;
		*"trust the files"*|*"Do you trust"*|*"trust this folder"*) echo "trust" ;;
		"") echo "starting" ;;
		*) echo "ok" ;;
	esac
}

# Never wait for a human: tools that were not pre-allowed are denied automatically ("dontAsk")
perm_mode() {
	if [ -z "$_PERM" ]; then
		if "$CLAUDE_BIN" --help 2>&1 | grep -q dontAsk; then _PERM=dontAsk; else _PERM=default; fi
	fi
	echo "$_PERM"
}
new_uuid() {
	if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
	elif [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
	else python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null; fi
}
# Result of a session: the JSON file, or else the ```yaybot block in the session transcript
session_result() { # id session-uuid
	local f="$YB_HOME/results/$1.json" tr
	if [ -s "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; then jq -c . "$f"; return 0; fi
	[ -n "$2" ] || return 1
	tr=$(find "$HOME/.claude/projects" -name "$2.jsonl" 2>/dev/null | head -1); [ -n "$tr" ] || return 1
	jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text
		| select(test("```yaybot")) | capture("```yaybot\\s*(?<j>[\\s\\S]*?)```").j] | last // empty' "$tr" 2>/dev/null \
		| jq -c 'select(type == "object")' 2>/dev/null | grep . || return 1
}

# Pick up the results of the ticket sessions (posts the private Slack replies)
collect_sessions() {
	local key t id allow started label res
	mkdir -p "$YB_HOME/results"
	for key in $(jq -r '.tickets | to_entries[] | select(.value.status == "session") | .key' "$STATE"); do
		t=$(jq -c --arg k "$key" '.tickets[$k]' "$STATE")
		id=$(jq -r .id <<<"$t"); allow=$(jq -r '.allow // 0' <<<"$t"); started=$(jq -r '.started // 0' <<<"$t")
		label="$id $(ticket_label "$(jq -r .channel <<<"$t")" "$(jq -r .ts <<<"$t")" "$(jq -r '.user // "?"' <<<"$t")" "$(jq -r .text <<<"$t")" "$(jq -r .tag <<<"$t")" "$(jq -r '.plugin // ""' <<<"$t")")"
		if res=$(session_result "$id" "$(jq -r '.sid // ""' <<<"$t")"); then
			say "Result from session $label"
			apply_result "$key" "$res" "$allow" "$label"
			st_update --arg i "$id" '.sessions[$i].done_at = now'
		elif sess_alive "$id" && [ "$(sess_state "yb-$id" | cut -c1-6)" = exited ]; then
			say "Session stopped without a result: $label"
			logf "session yb-$id stopped: $(pane_tail "yb-$id" 8 | tr '\n' ' ')"
			try_resume "$key" && continue
			apply_result "$key" "$(jq -nc --arg w "$(sess_state "yb-$id" | cut -c9- | cut -c1-200)" '{outcome:"needs_user",confidence:0,summary:"Claude could not run for this ticket",note:("claude stopped: " + $w)}')" 0 "$label"
			tmux kill-session -t "=yb-$id" 2>/dev/null
		elif ! sess_alive "$id"; then
			say "Session closed without a result: $label"
			try_resume "$key" && continue
			apply_result "$key" '{"outcome":"needs_user","confidence":0,"summary":"The ticket session was closed before Claude wrote a result","note":"session closed"}' 0 "$label"
		elif [ $(( $(date +%s) - ${started%.*} )) -gt "$SESSION_TIMEOUT" ]; then
			apply_result "$key" "{\"outcome\":\"needs_user\",\"confidence\":0,\"summary\":\"No result after $((SESSION_TIMEOUT / 60)) min — open session $id in the Claude app\",\"note\":\"timeout, session $id left open\"}" 0 "$label"
			st_update --arg i "$id" '.sessions[$i].done_at = now'
		fi
	done
	return 0
}

# Open the Remote Control session of a ticket. With "resume", continue its previous Claude
# conversation (claude --resume <session id>) — used after a power off / crash.
open_ticket_session() { # key [resume]
	local key=$1 how=${2:-new} t tag text ch ts user id allow label rc resfile prompt sysp plug pdir wt sid
	local tools=() mode adddir=() start=()
	t=$(jq -c --arg k "$key" '.tickets[$k]' "$STATE")
	tag=$(jq -r .tag <<<"$t"); text=$(jq -r .text <<<"$t"); ch=$(jq -r .channel <<<"$t"); ts=$(jq -r .ts <<<"$t"); user=$(jq -r '.user // "?"' <<<"$t")
	plug=$(jq -r '.plugin // ""' <<<"$t"); pdir=$(plugin_dir "$plug"); [ -d "$pdir" ] || pdir=""
	id=$(jq -r '.id // empty' <<<"$t")
	if [ -z "$id" ]; then st_update '.seq = ((.seq // 0) + 1)'; id="T$(jq -r .seq "$STATE")"; fi
	wt="$YB_HOME/worktrees/$id"
	allow=0; can_fix "$tag" "$pdir" && allow=1
	ticket_tools "$allow" "$pdir" "$wt" "$(plugin_docs "$plug")"; mode=$(perm_mode)
	adddir=(); [ -n "$pdir" ] && adddir=(--add-dir "$pdir")
	rc=$(printf '%s · %s · %s · %s' "$id" "$(plugin_name "$plug")" "$tag" "$(user_name "$user")" | cut -c1-$((78 - ${#DEVICE}))) ; rc="$rc · $DEVICE"
	label="$id $(ticket_label "$ch" "$ts" "$user" "$text" "$tag" "$plug")"
	resfile="$YB_HOME/results/$id.json"
	sysp=$(session_system "$id" "$tag" "$text" "$allow" "$ts" "$ch" "$user" "$resfile" "$plug")
	if [ "$how" = resume ]; then
		sid=$(jq -r '.sid // empty' <<<"$t")
		prompt="YayBot: this session was interrupted (the computer $DEVICE was switched off or Claude stopped). Continue ticket $id from where you were and finish it exactly as instructed: write the result JSON, run the collect command, show the short result and send the push notification."
		start=(--resume "$sid")
	else
		sid=$(new_uuid); rm -f "$resfile"
		prompt=$(session_prompt "$id" "$tag" "$text" "$allow" "$ts" "$ch" "$user" "$resfile" "$plug")
		start=(${sid:+--session-id "$sid"})
	fi
	# the session runs in ~/.yaybot (folder trusted once); the plugin's source folder is added read access
	trust_dir "$YB_HOME"
	tmux kill-session -t "=yb-$id" 2>/dev/null
	if env -u TMUX tmux new-session -d -s "yb-$id" -c "$YB_HOME" bash -c "$KEEP" yaybot \
		env -u YAYBOT_IN_RC YAYBOT_TICKET="$id" "$CLAUDE_BIN" --permission-mode "$mode" ${start[@]+"${start[@]}"} "$prompt" \
			--append-system-prompt "$sysp" ${adddir[@]+"${adddir[@]}"} --allowedTools "${tools[@]}" "Edit(/$resfile)" "Bash($(yb_cmd) collect)" \
			--remote-control "$rc"; then
		if [ "$how" = resume ]; then
			st_update --arg k "$key" '.tickets[$k] += {status:"session", started:now} | .tickets[$k].resumes = ((.tickets[$k].resumes // 0) + 1)'
			say "♻️  Resumed $label"; logf "session yb-$id resumed (claude --resume $sid): $label"
		else
			st_update --arg k "$key" --arg i "$id" --argjson a "$allow" --arg s "$sid" '.tickets[$k] += {status:"session", id:$i, allow:$a, started:now, sid:$s}'
			say "Claude is working on $label"; logf "session yb-$id started: $label"
		fi
		st_update --arg i "$id" --arg n "$rc" --arg d "$DEVICE" '.sessions[$i] = ((.sessions[$i] // {}) + {name:$n, started:now, device:$d}) | del(.sessions[$i].done_at)'
		say "  → Remote Control session \\"$rc\\" — open it in the Claude app; the result is pushed to your phone"
		sleep "${YAYBOT_START_WAIT:-6}"
		case "$(sess_state "yb-$id")" in
			trust) warn "Session $id is waiting for \\"Do you trust this folder?\\": run tmux attach -t yb-$id, choose Yes, then Ctrl+B D" ;;
			exited*) warn "Session $id stopped: $(sess_state "yb-$id" | cut -c9-)"; logf "session yb-$id stopped: $(pane_tail "yb-$id" 8 | tr '\\n' ' ')" ;;
		esac
		return 0
	fi
	warn "Could not open a session for $label — will retry next round"
	return 1
}

# A ticket session died without a result (power off, crash). Resume it if possible.
# → 0 when it was resumed or put back in the queue; 1 when it must go to the user
try_resume() { # key
	local key=$1 t n sid
	t=$(jq -c --arg k "$key" '.tickets[$k]' "$STATE")
	[ "$(jq -r '.closed_by_user // false' <<<"$t")" = true ] && return 1
	n=$(jq -r '.resumes // 0' <<<"$t"); [ "$n" -lt "$MAX_RESUMES" ] || return 1
	sid=$(jq -r '.sid // empty' <<<"$t")
	if [ -n "$sid" ] && find "$HOME/.claude/projects" -name "$sid.jsonl" 2>/dev/null | grep -q .; then
		open_ticket_session "$key" resume && return 0
	fi
	# no conversation to continue: start the ticket again (same number)
	st_update --arg k "$key" '.tickets[$k].status = "new" | .tickets[$k].resumes = ((.tickets[$k].resumes // 0) + 1)'
	say "♻️  $(jq -r .id <<<"$t") will be started again (no conversation to resume)"; logf "$(jq -r .id <<<"$t") put back in the queue"
	return 0
}

work_sessions() {
	local key id n_live
	# 1) results of the sessions that finished
	collect_sessions
	# 2) open a session for every new ticket (at most MAX_SESSIONS working at once)
	n_live=$(jq '[.tickets[] | select(.status == "session")] | length' "$STATE")
	for key in $(jq -r '.tickets | to_entries | sort_by(.value.ts) | .[] | select(.value.status == "new") | .key' "$STATE"); do
		if [ "$n_live" -ge "$MAX_SESSIONS" ]; then say "  (max $MAX_SESSIONS ticket sessions at once — the rest start next round)"; break; fi
		if open_ticket_session "$key"; then n_live=$((n_live + 1)); fi
	done
	# 3) close finished ticket sessions after KEEP_SESSIONS_HOURS
	for id in $(jq -r --argjson h "$KEEP_SESSIONS_HOURS" '.sessions // {} | to_entries[] | select(.value.done_at and (now - .value.done_at) > ($h * 3600)) | .key' "$STATE"); do
		tmux kill-session -t "=yb-$id" 2>/dev/null && logf "closed old session yb-$id"
		remove_worktree "$YB_HOME/worktrees/$id" >/dev/null 2>&1
		st_update --arg i "$id" 'del(.sessions[$i])'; rm -f "$YB_HOME/results/$id.json"
	done
	return 0
}

# What the phone shows as the first message of the session: just the ticket header + its first words
session_prompt() { # id tag text allow ts channel user resfile plugin
	printf 'YayBot ticket %s (on %s) — %s · Slack #%s · %s · from %s · type: %s\n“%s”' "$1" "$DEVICE" "$(plugin_name "$9")" "$(channel_name "$6")" \
		"$(fmt_date "${5%.*}" '+%Y-%m-%d %H:%M')" "$(user_name "$7")" "$2" \
		"$(flat "$3" | sed -E 's#<https?://[^>|]*\|?([^>]*)>#\1#g; s#<[^>]*>##g; s#^[[:space:]-]+##; s#[[:space:]]+# #g' | cut -c1-160)"
}
# The instructions go into the system prompt, so they are not shown on the phone
session_system() { # id tag text allow ts channel user resfile plugin
	cat <<EOF
This session works on YayBot ticket $1 (the first user message is its header).
$(work_prompt "$2" "$3" "$4" "$5" "$9" "$1" | sed '/^End with exactly one block:/,$d')

You are in a Claude Remote Control session that the user follows on the Claude app on their phone.
Work on your own from start to finish — NEVER wait for the user or ask for confirmation. Tools you are not
allowed to use are denied automatically: carry on with what you have. Do NOT post in Slack yourself: YayBot posts
your result in the ticket's thread, visible only to the user.

When you have finished, do these 4 things in order, without asking:
1. Use the Write tool to save the result as JSON (one object, nothing else) to:
   $8
   {"outcome":"answered|fixed|needs_user","confidence":0.0,"summary":"1-2 sentences","reply":"reply to send to the customer, in English","root_cause":"","fix_plan":"","pr_url":null}
   If writing the file fails, put the same JSON in a \`\`\`yaybot code block in your message instead.
2. Run the command: $(yb_cmd) collect
   (YayBot then posts the result in the ticket's Slack thread, visible only to the user — right away.)
3. Show the result here, SHORT — the user reads it on a phone. Exactly these 3 lines, nothing else
   (no headings, no long code, no closing sentence, no hint about what the user can ask):
   ✅ $1 answered   (or: ✅ $1 fixed · PR <url>   or: 🧑‍💻 $1 needs your fix)
   Cause: <one short sentence>
   Fix / answer: <one short sentence>
4. Send a push notification (PushNotification tool), one line under 80 characters:
   "<✅ or 🧑‍💻> $1 $2: <5-8 word summary>"
Then stay available: give the full analysis or the customer reply only when the user asks.
EOF
}

# ---- Mode 0: headless (claude -p), no session per ticket --------------------------
work_headless() {
	local key t tag text ch ts allow out res label plug pdir id
	local tools=() mode adddir=()
	# tickets stuck in "working" (machine went off / process killed) → retry
	st_update --argjson lim "$((CLAUDE_TIMEOUT + 120))" '.tickets |= with_entries(if .value.status == "working" and ((now - (.value.started // 0)) > $lim) then .value.status = "new" else . end)'
	for key in $(jq -r '.tickets | to_entries[] | select(.value.status == "new") | .key' "$STATE"); do
		t=$(jq -c --arg k "$key" '.tickets[$k]' "$STATE")
		tag=$(jq -r .tag <<<"$t"); text=$(jq -r .text <<<"$t"); ch=$(jq -r .channel <<<"$t"); ts=$(jq -r .ts <<<"$t")
		st_update --arg k "$key" '.tickets[$k].status = "working" | .tickets[$k].started = now'
		plug=$(jq -r '.plugin // ""' <<<"$t"); pdir=$(plugin_dir "$plug"); [ -d "$pdir" ] || pdir=""
		label=$(ticket_label "$ch" "$ts" "$(jq -r '.user // "?"' <<<"$t")" "$text" "$tag" "$plug")
		say "Claude is working on $label"; logf "working on $label"
		id="H${ts%.*}"
		allow=0; can_fix "$tag" "$pdir" && allow=1
		ticket_tools "$allow" "$pdir" "$YB_HOME/worktrees/$id" "$(plugin_docs "$plug")"
		adddir=(); [ -n "$pdir" ] && adddir=(--add-dir "$pdir")
		out=$(cd "$YB_HOME" && work_prompt "$tag" "$text" "$allow" "$ts" "$plug" "$id" \
			| with_timeout "$CLAUDE_TIMEOUT" "$CLAUDE_BIN" -p --output-format json --permission-mode "$mode" --max-turns 40 ${adddir[@]+"${adddir[@]}"} \
				--append-system-prompt "You are running unattended inside YayBot; nobody will answer questions. Finish with the yaybot JSON block." \
				--allowedTools "${tools[@]}" 2>>"$LOG")
		res=$(jq -c '.result // "" | (capture("```yaybot\\s*(?<j>[\\s\\S]*?)```").j // "") | try fromjson catch {}' <<<"$out" 2>/dev/null)
		apply_result "$key" "$res" "$allow" "$label"
	done
}

work_prompt() { # tag text allow_fix ts plugin id
	local name dir wt docs
	name=$(plugin_name "$5"); dir=$(plugin_dir "$5"); [ -d "$dir" ] || dir=""; wt="$YB_HOME/worktrees/$6"; docs=$(plugin_docs "$5")
	cat <<EOF
You are a support engineer for the WordPress plugin $name. Ticket from Slack (type: $1):

<<<
$2
>>>

$( [ -n "$dir" ] && echo "The source code of $name is in $dir: read CLAUDE.md, README/readme.txt, docs/ and the relevant code before concluding." || echo "No source code available: rely on your knowledge of $name/WordPress/WooCommerce." )
$( [ -n "$docs" ] && printf 'Documentation of %s (from the docs list):\n%s\n%s\n' "$name" "$(printf '%s\n' "$docs" | sed 's/^/- /')" "For how-to and trivial tickets you MUST, besides the source code, use this documentation: open these links with WebFetch,
follow their links to find the guide page that matches the ticket, use the exact menu names / settings from it,
and put the link of that guide page in the customer reply. If the docs and the code do not confirm your answer,
set confidence below $MIN_CONFIDENCE (the ticket then goes to the user)." )
$( if [ "$3" = 1 ]; then echo "You MAY fix it, but never in $dir itself: run \`git -C $dir worktree add $wt -b yaybot/$6\`, make a minimal change in $wt, then commit and push with \`git -C $wt …\` and open a PR with \`cd $wt && gh pr create …\`. Do NOT merge, do NOT deploy."; else echo "READ-ONLY: do not edit files, do not push, do not deploy."; fi )

Task:
- how-to: write the answer for the customer (step by step, exact menu names) → outcome "answered".
- bug: find the root cause and propose a concrete fix (file/function). If you opened a PR → "fixed". If not fixed or not sure → "needs_user".
- Missing information → "needs_user" and put the questions for the customer in reply.
Be honest about confidence (0–1).

End with exactly one block:
\`\`\`yaybot
{"outcome":"answered|fixed|needs_user","confidence":0.0,"summary":"1-2 sentences","reply":"reply to send to the customer, in English","root_cause":"","fix_plan":"","pr_url":null}
\`\`\`
EOF
}

# Report (Markdown) printed to the screen + saved in ~/.yaybot/reports/. NOTHING is sent to Slack.
# In the Claude Remote Control session, Claude reads this output and shows it on your phone.
cmd_report() {
	local force=$1 n_done n_open text key ch ts link file
	n_done=$(jq '[.tickets[] | select(.status == "done")] | length' "$STATE")
	n_open=$(jq '[.tickets[] | select(.status != "done")] | length' "$STATE")
	if [ "$force" != "force" ]; then
		[ "$n_done" = 0 ] && [ "$n_open" != 0 ] && { say "YAYBOT: $n_open ticket(s) being worked on in their own sessions."; return 0; }
		[ "$n_done" = 0 ] && { say "YAYBOT: nothing new."; return 0; }
		# finished tickets are reported right away; tickets still in a session are listed as pending
	fi
	[ "$n_done" = 0 ] && [ "$n_open" = 0 ] && { say "YAYBOT: no tickets."; return 0; }
	for key in $(jq -r '.tickets | keys[]' "$STATE"); do
		ch=${key%%:*}; ts=${key#*:}
		link=$(permalink "$ch" "$ts")
		st_update --arg k "$key" --arg l "$link" --arg n "$(channel_name "$ch")" --arg pn "$(plugin_name "$(jq -r --arg k "$key" '.tickets[$k].plugin // ""' "$STATE")")" --arg u "$(user_name "$(jq -r --arg k "$key" '.tickets[$k].user // "?"' "$STATE")")" \
			'.tickets[$k] += {link:$l, cname:$n, uname:$u, pname:$pn}'
	done
	text=$(jq -r --arg when "$(date '+%Y-%m-%d %H:%M')" --arg plugin "${PLUGIN:-plugin} · $DEVICE" '
		def clean: gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | gsub("^[\\s-]+"; "");
		def line: "- " + (if (.link // "") != "" then "[#" + .cname + "](" + .link + ")" else "#" + .cname end) + " **" + (.pname // .plugin // "?") + "** `" + .tag + "` · " + (.ts | tonumber | strflocaltime("%Y-%m-%d %H:%M")) + " · " + (.uname // .user) + " — “" + ((.text | clean)[0:100]) + "”" + (if .id then " · session " + .id else "" end);
		[.tickets[]] as $all
		| ($all | map(select(.status == "done" and .outcome != "needs_user"))) as $ok
		| ($all | map(select(.status == "done" and .outcome == "needs_user"))) as $bad
		| ($all | map(select(.status != "done"))) as $open
		| "## 📋 YayBot report — \($plugin) (\($when))",
		  "**Total: \($all | length) ticket(s)** · ✅ Handled by Claude: \($ok | length) · 🧑‍💻 You need to fix: \($bad | length) · ⏳ Pending: \($open | length)",
		  "",
		  "By type: " + ([("how-to","trivial","technical","major","fatal") as $t | "\($t) \($all | map(select(.tag == $t)) | length)"] | join(" · ")),
		  "",
		  "### ✅ Fixed / answered by Claude (\($ok | length))",
		  (if ($ok | length) == 0 then "_none_" else ($ok[] | line,
		     "  - Result: " + (.result.summary // "") + (if (.result.pr_url // "") != "" then " · PR: " + .result.pr_url else "" end),
		     (if (.result.reply // "") != "" then "  - 💬 Suggested reply to the customer: " + (.result.reply | gsub("\\s+"; " "))[0:400] else empty end)) end),
		  "",
		  "### 🧑‍💻 You need to fix (\($bad | length))",
		  (if ($bad | length) == 0 then "_none_" else ($bad[] | line,
		     "  - " + (.result.summary // "") + (if (.result.note // "") != "" then " (" + .result.note + ")" else "" end),
		     (if (.result.root_cause // "") != "" then "  - Root cause: " + .result.root_cause[0:300] else empty end),
		     (if (.result.fix_plan // "") != "" then "  - Suggested fix: " + .result.fix_plan[0:300] else empty end),
		     (if (.result.reply // "") != "" then "  - 💬 Draft reply / questions for the customer: " + (.result.reply | gsub("\\s+"; " "))[0:300] else empty end)) end),
		  (if ($open | length) > 0 then "", "### ⏳ Pending (\($open | length))", ($open[] | line) else empty end)
	' "$STATE")
	mkdir -p "$YB_HOME/reports"
	file="$YB_HOME/reports/$(date '+%Y%m%d-%H%M%S').md"
	printf '%s\n' "$text" > "$file"
	# short version for the phone: one line per ticket; the full report stays in the file
	jq -r --arg when "$(date '+%d/%m %H:%M')" --arg plugin "${PLUGIN:-plugin} · $DEVICE" '
		def clean: gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | gsub("^[\\s-]+"; "");
		def cut($n): if length > $n then .[0:$n] + "…" else . end;
		[.tickets[]] as $all
		| ($all | map(select(.status == "done" and .outcome != "needs_user"))) as $ok
		| ($all | map(select(.status == "done" and .outcome == "needs_user"))) as $bad
		| ($all | map(select(.status != "done"))) as $open
		| "📋 \($plugin) · \($when) — \($ok | length + ($bad | length)) ticket(s): ✅ \($ok | length) · 🧑‍💻 \($bad | length)\(if ($open | length) > 0 then " · ⏳ \($open | length)" else "" end)",
		  ($bad[] | "🧑‍💻 \(.id // "")\(if .id then " " else "" end)\(.tag) · \(.uname // .user) — \((.result.summary // .text) | clean | cut(70))"),
		  ($ok[]  | "✅ \(.id // "")\(if .id then " " else "" end)\(.tag) · \(.uname // .user) — \((.result.summary // .text) | clean | cut(70))")
	' "$STATE" > "${file%.md}.short"
	cat "${file%.md}.short"
	say "(full report: $file)"
	logf "report $file ($n_done done)"
	# drop reported tickets; remember them as "seen" for 7 days so they are not picked up again; keep the last 30 reports
	st_update '.seen += ([.tickets | to_entries[] | select(.value.status == "done") | {key: .key, value: now}] | from_entries)
		| .tickets |= with_entries(select(.value.status != "done"))
		| .seen |= with_entries(select(.value > (now - 604800)))'
	ls -1t "$YB_HOME/reports/"*.md 2>/dev/null | tail -n +31 | while IFS= read -r f; do rm -f "$f" "${f%.md}.short"; done
	return 0
}

# ---- Delivery to the Claude Remote Control session ---------------------------------
# Every report is also delivered to the Remote Control session "YayBot", so it shows up
# on your phone (Claude app) — even when `yb run` was typed in a Terminal.
latest_report() { ls -1t "$YB_HOME/reports/"*.md 2>/dev/null | head -1; }
mark_delivered() { echo "$(basename "$1")" >> "$YB_HOME/reports/.delivered"; }
# Inside the Remote Control session: print every report it has not shown yet (oldest first)
print_undelivered() {
	local f
	for f in $(ls -1tr "$YB_HOME/reports/"*.md 2>/dev/null); do
		grep -qxF "$(basename "$f")" "$YB_HOME/reports/.delivered" 2>/dev/null && continue
		printf '\n'; if [ -s "${f%.md}.short" ]; then cat "${f%.md}.short"; else cat "$f"; fi; mark_delivered "$f"
	done
}
rc_running() { command -v tmux >/dev/null 2>&1 && tmux has-session -t yaybot 2>/dev/null; }
# Ask the Remote Control session to show the new report now
rc_nudge() {
	tmux send-keys -t yaybot -l "New YayBot report: run \`$(yb_cmd) run\` now, show only the 📋 lines and send a PushNotification with the 📋 line." \
		&& tmux send-keys -t yaybot Enter
}
notify_rc() {
	if rc_running; then
		rc_nudge && say "→ Report sent to the Claude Remote Control session \"$RC_LABEL\" — open the Claude app on your phone."
	elif command -v tmux >/dev/null 2>&1 && command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
		cmd_start >/dev/null 2>&1 || { warn "Could not start the Remote Control session (see: yb start)"; return; }
		# give Claude Code time to start before asking it to show the report
		( sleep "${YAYBOT_NUDGE_DELAY:-25}"; rc_running && rc_nudge ) >/dev/null 2>&1 &
		say "→ Started the Claude Remote Control session \"$RC_LABEL\"; the report will appear there in ~30 s — open the Claude app on your phone."
	else
		warn "Report not sent to your phone: tmux and claude are needed for the Remote Control session (yb start)"
	fi
}

cmd_run() {
	c_g=; c_r=; c_y=; c_b=; c_0=
	need; need_token; st_init; lock
	local before after
	before=$(latest_report)
	cmd_listen; cmd_work; cmd_report
	after=$(latest_report)
	if [ "$YAYBOT_IN_RC" = 1 ]; then
		# running inside the Remote Control session: the report just printed is delivered,
		# plus any report created meanwhile from a Terminal
		[ -n "$after" ] && [ "$after" != "$before" ] && mark_delivered "$after"
		print_undelivered
	elif [ -n "$after" ] && [ "$after" != "$before" ]; then
		notify_rc
	fi
}

# ---- yb plugin <Name>: the ONE plugin YayBot supports --------------------------------
conf_get() { [ -f "$CONF" ] && sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$CONF" | tail -1; }
conf_set() { # NAME value
	local tmp; tmp=$(mktemp "$YB_HOME/.conf.XXXXXX")
	{ grep -v "^$1=" "$CONF" 2>/dev/null; printf '%s="%s"\n' "$1" "$2"; } > "$tmp" && cat "$tmp" > "$CONF"; rm -f "$tmp"
	chmod 600 "$CONF"
}
key_of() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'; }

# All channels the bot can see (public + private ones it was invited to), sorted by name
CHLIST=""
CHLIST_ERR=""
list_channels() {
	[ -n "$CHLIST" ] && return 0
	local page cursor="" all='[]' types="public_channel,private_channel" err tries=0
	while :; do
		page=$(curl -sS -m 30 -X POST "$API_BASE/conversations.list" -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
			--data-urlencode "types=$types" --data-urlencode "exclude_archived=true" --data-urlencode "limit=200" ${cursor:+--data-urlencode "cursor=$cursor"} 2>&1)
		if [ "$(jq -r '.ok // false' <<<"$page" 2>/dev/null)" != true ]; then
			err=$(jq -r '"\(.error // "no answer from Slack")\(if .needed then " (needs scope: " + .needed + "; this token only has: " + (.provided // "?") + ")" else "" end)"' <<<"$page" 2>/dev/null || echo "no answer from Slack: $page")
			case "$err" in
				ratelimited*) tries=$((tries + 1)); [ $tries -le 5 ] && { sleep 3; continue; } ;;
				missing_scope*) # no groups:read → list the public channels only
					if [ "$types" != public_channel ]; then types=public_channel; cursor=""; all='[]'; CHLIST_ERR="private channels not listed: $err"; continue; fi ;;
			esac
			CHLIST_ERR=$err; break
		fi
		all=$(jq -c --argjson a "$all" '$a + [(.channels // [])[] | {id, name, member: (.is_member // false), private: (.is_private // false)}]' <<<"$page")
		cursor=$(jq -r '.response_metadata.next_cursor // ""' <<<"$page"); [ -n "$cursor" ] || break
	done
	CHLIST=$(jq -c 'unique_by(.id) | sort_by(.name)' <<<"$all")
}
# Show every channel with a number; the user picks the ones that support the plugin.
# Prints the answer (numbers / names, ":all" allowed). Screen output goes to stderr.
pick_channels() { # plugin-name current-tokens
	local cur=$2 ans curnames="" t
	list_channels
	{
		say ""; say "${c_b}Slack channels YayBot can see${c_0} ($(jq length <<<"$CHLIST")):"
		if [ -n "$CHLIST_ERR" ]; then
			warn "Slack conversations.list: $CHLIST_ERR"
			case "$CHLIST_ERR" in
				*missing_scope*|*needs\ scope*) say "  Fix: run ${c_b}yb check${c_0} — it shows which Slack app this token belongs to, its scopes, and the exact steps." ;;
				*invalid_auth*|*not_authed*|*token*) say "  Fix: the token is wrong or was revoked — run: yb setup xoxb-…" ;;
			esac
		fi
		if [ "$(jq length <<<"$CHLIST")" = 0 ]; then
			say "  You can still type the channels: paste a channel link (in Slack: right-click the channel → Copy → Copy link) or its ID (C0123…)."
		fi
		jq -r --arg cur " $cur " 'to_entries[] | .value as $v | ((.key + 1) | tostring) as $n
			| "  \(" " * (3 - ($n | length)) // "")\($n). #\($v.name)\(if $v.private then "  (private)" else "" end)\(if ($cur | contains(" " + $v.id + " ") or contains(" " + $v.id + ":all ")) then "  ← current" else "" end)"' <<<"$CHLIST"
		say ""
		say "Pick the channels that support $1: type their numbers, names, links or IDs, e.g. ${c_b}2 5${c_0} or ${c_b}#support-guabin${c_0}."
		say "Add ${c_b}:all${c_0} when every message in that channel is a $1 ticket, e.g. ${c_b}5:all${c_0} (channels named after $1 count as :all automatically)."
		say "Private channel missing? Type /invite @YayBot in it first."
	} >&2
	if [ -n "$cur" ]; then
		for t in $cur; do curnames="$curnames #$(channel_name "${t%:all}")$( case "$t" in *:all) printf ':all' ;; esac)"; done
		printf 'Channels for %s [Enter = keep%s]: ' "$1" "$curnames" >&2
	else
		printf 'Channels for %s: ' "$1" >&2
	fi
	read -r ans
	[ -n "$ans" ] && printf '%s' "$ans" || printf '%s' "$cur"
}

# yb plugin <Name> [#channel …]
# 1) source code in PLUGINS_DIR   2) keywords   3) the Slack channels YOU name (no searching)
cmd_plugin() {
	need; need_token; st_init
	local base docs code want="$1" key f hdr fname short slug k1 k2 score best=0 dir="" name desc="" pat kwpat kw out
	local list='' cursor="" page ch cname member priv cnt total dedicated chosen="" dedi="" n tmp tok all given=""
	[ $# -gt 0 ] && shift; given="$*"
	[ -n "$want" ] || want=$PLUGIN
	if [ -z "$want" ]; then
		[ -t 0 ] || die "No plugin chosen yet. Type for example: yb plugin YayExtra"
		printf 'Which plugin should YayBot support? (e.g. YayExtra): '; read -r want
		[ -n "$want" ] || die "No plugin chosen. Type for example: yb plugin YayExtra"
	fi
	key=$(key_of "$want"); name=$want
	tmp=$(mktemp -d "$YB_HOME/.plugin.XXXXXX")
	say "${c_b}YayBot will support: $want${c_0}"

	# 1) does PLUGINS_DIR contain this plugin's source? (folder name or "Plugin Name:" header)
	say ""; say "${c_b}1. Source code${c_0} (in $PLUGINS_DIR)"
	if [ -d "$PLUGINS_DIR" ]; then
		for f in "$PLUGINS_DIR"/*/*.php; do
			[ -f "$f" ] || continue
			[ "$(dirname "$f")" = "$(dirname "$SELF")" ] && continue
			hdr=$(head -c 8192 "$f" | tr -d '\r')
			fname=$(printf '%s\n' "$hdr" | sed -n 's/^[[:space:]*#@/]*Plugin Name:[[:space:]]*//p' | head -1 | sed 's/[[:space:]]*$//')
			[ -n "$fname" ] || continue
			short=$(printf '%s' "$fname" | sed -E 's/[[:space:]]+[-–—|:(].*$//')
			slug=$(basename "$(dirname "$f")"); k1=$(key_of "$slug"); k2=$(key_of "$short")
			score=0
			if [ "$k1" = "$key" ] || [ "$k2" = "$key" ]; then score=3
			elif case "$k1" in "$key"*) true ;; *) false ;; esac || case "$k2" in "$key"*) true ;; *) false ;; esac; then score=2
			elif printf '%s' "$fname" | grep -qiF "$want"; then score=1; fi
			if [ $score -gt $best ]; then
				best=$score; dir=$(dirname "$f"); name=$short
				desc=$(printf '%s\n' "$hdr" | sed -n 's/^[[:space:]*#@/]*Description:[[:space:]]*//p' | head -1 | cut -c1-200)
			fi
		done
	fi
	if [ -n "$dir" ]; then
		ok "Found $name: $dir"
		git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 \
			&& ok "It is a git repo: Claude may fix \`$AUTO_FIX_TAGS\` tickets in a separate worktree and open a PR" \
			|| say "  (not a git repo: Claude reads the code but does not open PRs)"
	else
		warn "No source code for $want in $PLUGINS_DIR — Claude will rely on its own knowledge."
		say "  If the code is in another folder: yb setup $(printf '%s' "$SLACK_BOT_TOKEN" | cut -c1-5)… <folder with the plugins>"
	fi
	# "YayCurrency Pro" → base "YayCurrency": tickets, channels and docs use the base name
	base=$name
	for _s in 1 2; do
		case "$(printf '%s' "$base" | tr 'A-Z' 'a-z')" in
			*" pro"|*" premium"|*" lite"|*" free"|*" plus"|*" business"|*" basic"|*" starter"|*" agency") base=${base% *} ;;
		esac
	done
	key=$(key_of "$base")

	# 2) keywords that customers use for this plugin (Claude, small model)
	kw='[]'
	case "$key" in yaycurrency) kw='["currency","currencies","exchange rate","conversion rate","multi currency","currency switcher"]' ;; esac
	if [ "$CLASSIFIER" = "claude" ] && command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
		out=$(printf 'YAYBOT_KEYWORDS\nList 3-8 short lowercase keywords or phrases that customers use when they report a problem with the WordPress plugin "%s"%s (its distinctive features). Avoid generic words (price, cart, product, order, checkout, woocommerce, plugin, settings, error).\n\nAnswer with JSON only: {"%s":["keyword", …]}' "$name" "${desc:+ — $desc}" "$key" \
			| with_timeout 120 "$CLAUDE_BIN" -p --output-format json --model "$CLAUDE_MODEL" --max-turns 1 2>/dev/null)
		kw=$(jq -c --argjson base "$kw" --arg k "$key" '.result | (try fromjson catch (capture("(?<j>\\{[\\s\\S]*\\})").j | fromjson)) | (.[$k] // ([.[]] | add) // []) | map(ascii_downcase) + $base | unique' <<<"$out" 2>/dev/null)
		jq -e 'type == "array"' <<<"$kw" >/dev/null 2>&1 || kw='[]'
	fi
	# keep keywords edited by hand ("edited": true) when it is the same plugin
	if [ -s "$PLUGINS_FILE" ] && [ "$(jq -r --arg k "$key" '.plugins[0] | (.slug == $k and .edited == true)' "$PLUGINS_FILE")" = true ]; then
		kw=$(jq -c '.plugins[0].keywords' "$PLUGINS_FILE"); n=edited
	fi
	jq -n --arg k "$key" --arg n "$name" --arg b "$base" --arg w "$want" --arg f "$(basename "${dir:-x}")" --arg d "$dir" --argjson kw "$kw" --arg ed "${n:-}" \
		'def split: gsub("(?<a>[a-z])(?<b>[A-Z])"; "\(.a) \(.b)");
		{plugins: [{slug: $k, name: $n, dir: $d,
			names: ([$n, $b, $w, $k, ($b | split)] + (if $d != "" then [$f] else [] end) | map(select(length > 2)) | unique),
			keywords: $kw} + (if $ed == "edited" then {edited: true} else {} end)]}' > "$tmp/plugins.json"
	pat=$(jq -r 'def rx: gsub("(?<c>[.+*?()\\[\\]{}^$|\\\\])"; "\\\(.c)") | gsub("[ _-]+"; "[ _-]?") | gsub("(?<a>[A-Za-z])\\k<a>"; "\(.a){1,2}"); .plugins[0].names | map(rx) | unique | join("|")' "$tmp/plugins.json")
	kwpat=$(jq -r 'def rx: gsub("(?<c>[.+*?()\\[\\]{}^$|\\\\])"; "\\\(.c)") | gsub("[ _-]+"; "[ _-]?") | gsub("(?<a>[A-Za-z])\\k<a>"; "\(.a){1,2}"); .plugins[0] | (.names + .keywords) | map(rx) | unique | join("|")' "$tmp/plugins.json")
	docs=$(plugin_docs "$key")
	if [ -f "$(docs_file)" ]; then say "  Docs list: $(docs_file)"; else say "  (no docs list: create $(docs_file) with the documentation links)"; fi
	printf '%s\n' "$docs" | grep . | head -8 | while IFS= read -r u; do
		code=$(curl -s -o /dev/null -w '%{http_code}' -L -m 20 "$u" 2>/dev/null)
		case "$code" in 2*) ok "Docs: $u" ;; *) warn "Docs: $u did not answer (HTTP ${code:-?})" ;; esac
	done
	say ""; say "${c_b}2. Keywords${c_0} used to recognise $name tickets: $(jq -r '.plugins[0] | (.names + .keywords) | unique | join(", ")' "$tmp/plugins.json")"

	# 3) the Slack channels that support this plugin — YOU pick them from the list
	if [ "$given" = "--pick" ]; then given=""
	elif [ -z "$given" ] && [ "$(key_of "$PLUGIN")" = "$key" ] && [ -n "$CHANNELS" ]; then
		for ch in $CHANNELS; do
			case " $CHANNEL_PLUGINS " in *" $ch="*) given="$given $ch:all" ;; *) given="$given $ch" ;; esac
		done
		[ -t 0 ] && given=$(pick_channels "$name" "$given")
	fi
	if [ -z "$given" ]; then
		[ -t 0 ] || { rm -rf "$tmp"; die "Which Slack channels support $name? Type: yb channels (shows the list to pick from)"; }
		given=$(pick_channels "$name" "")
		[ -n "$given" ] || { rm -rf "$tmp"; die "No channel chosen. Type: yb channels"; }
	fi
	say ""; say "${c_b}3. Slack channels for $name${c_0} (checking the last $DETECT_DAYS days)"
	total=0
	for tok in $(printf '%s' "$given" | tr ',' ' '); do
		all=0
		case "$tok" in *:all) all=1; tok=${tok%:all} ;; esac
		tok=$(printf '%s' "$tok" | sed -E 's/^<#([A-Z0-9]+)(\|[^>]*)?>$/\1/; s#^https?://[^/]+/(archives|client/[A-Z0-9]+)/([A-Z0-9]+).*$#\2#; s/^#//')
		[ -n "$tok" ] || continue
		ch=""; cname=""; member=true; priv=false
		if printf '%s' "$tok" | grep -qE '^[CG][A-Z0-9]{6,}$'; then
			ch=$tok; cname=$(channel_name "$ch")
		else
			# a number from the list, or a channel name → ID
			list_channels
			IFS=$'\t' read -r ch cname member priv < <(jq -r --arg n "$tok" 'to_entries[] | select((.key + 1 | tostring) == $n or (.value.name | ascii_downcase) == ($n | ascii_downcase)) | .value | [.id, .name, (.member | tostring), (.private | tostring)] | @tsv' <<<"$CHLIST" | head -1)
			if [ -z "$ch" ]; then say "  ${c_r}✗${c_0} $tok — not in the channel list (wrong name, or a private channel: type /invite @YayBot there first)"; continue; fi
		fi
		if [ "$member" != true ] && [ "$priv" != true ]; then
			api conversations.join "channel=$ch" >/dev/null 2>&1   # the bot must be a member to read (Slack shows one "joined" line)
		fi
		history "$ch" "$(to_epoch "$DETECT_DAYS").000000" > "$tmp/h" 2>/dev/null || { say "  ${c_r}✗${c_0} #$cname — cannot read it (private channel: type /invite @YayBot there)"; continue; }
		n=$(wc -l < "$tmp/h" | tr -d ' ')
		# a channel named after the plugin (or marked :all) → every message is a ticket
		printf '%s' "$cname" | grep -qiE "$pat" && all=1
		case " $chosen " in *" $ch "*) continue ;; esac
		chosen="$chosen $ch"
		if [ $all = 1 ]; then
			say "  ${c_g}✓${c_0} #$cname — only about $name: every message is a ticket ($n message(s))"
			dedi="$dedi $ch=$key"; total=$((total + n))
		else
			cnt=$(jq -r '.text // "" | gsub("\\s+"; " ")' "$tmp/h" | grep -ciE "$kwpat")
			say "  ${c_g}✓${c_0} #$cname — shared channel: only messages about $name are tickets ($cnt of $n message(s))"
			total=$((total + cnt))
		fi
	done
	chosen=${chosen# }; dedi=${dedi# }

	# save: plugin, its channels; a different plugin starts from a clean queue
	jq --argjson ch "$(printf '%s\n' $dedi | jq -R -s -c 'split("\n") | map(select(. != "") | split("=")[0])')" '.plugins[0].channels = $ch' "$tmp/plugins.json" > "$PLUGINS_FILE"
	if [ "$(key_of "$PLUGIN")" != "$key" ]; then st_update '.cursor = {} | .tickets |= with_entries(select(.value.status == "session"))'; fi
	PLUGIN=$name; CHANNELS=$chosen; CHANNEL_PLUGINS=$dedi; PATTERNS=""
	conf_set PLUGIN "$PLUGIN"; conf_set CHANNELS "$CHANNELS"; conf_set CHANNEL_PLUGINS "$CHANNEL_PLUGINS"
	rm -rf "$tmp"
	say ""
	if [ -n "$CHANNELS" ]; then
		ok "YayBot will read $(printf '%s\n' $CHANNELS | grep -c .) channel(s) for $name ($total ticket message(s) in the last $DETECT_DAYS days)"
	else
		warn "No readable channel. Check the names, invite YayBot to private channels (/invite @YayBot), then run: yb plugin $name #channel …"
	fi
}

cmd_plugin_show() {
	[ -s "$PLUGINS_FILE" ] || { cmd_plugin; return; }
	local ch
	say "${c_b}Plugin:${c_0} $(jq -r '.plugins[0].name' "$PLUGINS_FILE")"
	say "  source:   $(jq -r '.plugins[0].dir | if . == "" then "none (Claude uses its own knowledge)" else . end' "$PLUGINS_FILE")"
	say "  docs:     $(plugin_docs "$(jq -r '.plugins[0].slug' "$PLUGINS_FILE")" | tr '\n' ' ') (list: $(docs_file))"
	say "  keywords: $(jq -r '.plugins[0] | (.names + .keywords) | unique | join(", ")' "$PLUGINS_FILE")"
	say "  channels:"
	for ch in $CHANNELS; do
		case " $CHANNEL_PLUGINS " in *" $ch="*) say "    #$(channel_name "$ch") (every message is a ticket)" ;; *) say "    #$(channel_name "$ch")" ;; esac
	done
	[ -n "$CHANNELS" ] || say "    none yet — run: yb channels"
	say ""; say "Change the channels: ${c_b}yb channels${c_0} (pick from the list) · another plugin: ${c_b}yb plugin <Name>${c_0}"
}

# ---- yb slack: your Slack member ID (the thread replies are "Only visible to you") ------
find_user() { # name | @name | U123 → ID
	local q=${1#@} page cursor="" id=""
	# a member ID (U0C6J69RSVD) is accepted when Slack knows it
	if printf '%s' "$q" | grep -qE '^[UW][A-Z0-9_]{5,}$' && api users.info "user=$q" >/dev/null 2>&1; then echo "$q"; return; fi
	while :; do
		page=$(api users.list "limit=200" ${cursor:+"cursor=$cursor"}) || return 1
		id=$(jq -r --arg q "$q" '[.members[] | select(.deleted != true and .is_bot != true)
			| select([.name, .real_name, .profile.display_name, .profile.real_name] | map(select(. != null) | ascii_downcase) | index($q | ascii_downcase))
			| .id][0] // empty' <<<"$page")
		[ -n "$id" ] && { echo "$id"; return; }
		cursor=$(jq -r '.response_metadata.next_cursor // ""' <<<"$page"); [ -n "$cursor" ] || break
	done
	return 1
}
cmd_slack() { # [your Slack name or member ID]
	need; need_token; st_init
	local who="$*" id ch
	say "${c_b}YayBot on Slack${c_0}: the result of each ticket is posted in its thread, visible ONLY to you."
	if [ -z "$who" ]; then
		if [ -t 0 ]; then
			printf 'Your Slack name or member ID (Profile → ⋮ → Copy member ID)%s: ' "${MY_SLACK_ID:+ [Enter = $(user_name "$MY_SLACK_ID")]}"; read -r who
		fi
		[ -n "$who" ] || who=$MY_SLACK_ID
		[ -n "$who" ] || die "Who are you on Slack? Run: yb slack <your Slack name or member ID>"
	fi
	id=$(find_user "$who") || die "No Slack member \"$who\" found. Use your member ID (in Slack: your profile → ⋮ → Copy member ID)"
	MY_SLACK_ID=$id; conf_set MY_SLACK_ID "$id"; ok "You: $(user_name "$id") ($id) — thread replies are visible only to you"
	# test: a message only you can see, in the first support channel
	ch=${CHANNELS%% *}
	if [ -n "$ch" ]; then
		api chat.postEphemeral "channel=$ch" "user=$MY_SLACK_ID" "text=🤖 YayBot test — only you can see this message. Ticket results will appear in their threads like this." >/dev/null \
			&& ok "Test message posted in #$(channel_name "$ch") — only you can see it" \
			|| warn "Could not post a message to you in #$(channel_name "$ch") (you must be a member of the channel; scope chat:write — yb check)"
	fi
}

# ---- After the computer starts: bring YayBot back (run by the LaunchAgent, or by hand) ----
cmd_boot() {
	c_g=; c_r=; c_y=; c_b=; c_0=
	need; st_init
	logf "boot: computer started"
	say "$(date '+%Y-%m-%d %H:%M:%S') YayBot boot on $DEVICE"
	if [ ! -f "$YB_HOME/.running" ]; then
		say "YayBot was stopped before (yb stop) — not starting it."; logf "boot: YayBot was stopped — nothing to do"; return 0
	fi
	if command -v tmux >/dev/null 2>&1 && tmux has-session -t =yaybot 2>/dev/null; then
		say "YayBot is already running — nothing to recover."; logf "boot: already running"; start_watch; return 0
	fi
	need_token
	# wait for the network (Wi-Fi may need a minute after login)
	local i=0 n
	until api auth.test >/dev/null 2>&1; do
		i=$((i + 1)); [ $i -gt 30 ] && { logf "boot: Slack not reachable after 5 min — giving up (run: yb start)"; die "Slack not reachable"; }
		sleep 10
	done
	# nothing survived the shutdown: old lock and "working" tickets are stale
	[ -d "$YB_HOME/.lock" ] && { rm -rf "$YB_HOME/.lock"; logf "boot: removed stale lock"; }
	st_update '.tickets |= map_values(if .status == "working" then .status = "new" else . end)'
	n=$(jq '[.tickets[] | select(.status == "session")] | length' "$STATE")
	say "Tickets that were being worked on: $n (they are resumed)"
	cmd_start
	cmd_run
	logf "boot: YayBot is back — $n ticket(s) were in progress"
	say "YayBot is back."
}

# Start YayBot automatically when you log in to the Mac (macOS LaunchAgent)
AGENT_ID="com.yaybot.boot"
cmd_autostart() { # on | off | (status)
	local plist="$HOME/Library/LaunchAgents/$AGENT_ID.plist" path cdir
	case "$(uname -s)" in Darwin) ;; *) die "Autostart is for macOS (LaunchAgent). On Linux add to crontab -e:  @reboot sleep 60 && $SELF boot" ;; esac
	case "${1:-status}" in
	on)
		cdir=$(dirname "$(command -v "$CLAUDE_BIN" 2>/dev/null || echo /usr/local/bin/claude)")
		path="$cdir:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
		mkdir -p "$HOME/Library/LaunchAgents"
		# The plugins usually live in ~/Documents, which macOS protects: a script started directly by
		# launchd may not read it. So the agent opens Terminal (which you already allowed) to run boot.
		cat > "$YB_HOME/boot.command" <<EOF
#!/bin/bash
export PATH="$path"
export YAYBOT_HOME="$YB_HOME"
/bin/bash "$SELF" boot 2>&1 | tee -a "$YB_HOME/boot.log"
EOF
		chmod +x "$YB_HOME/boot.command"
		cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$AGENT_ID</string>
	<key>ProgramArguments</key>
	<array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>Terminal</string><string>$YB_HOME/boot.command</string></array>
	<key>RunAtLoad</key><true/>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key><string>$path</string>
		<key>HOME</key><string>$HOME</string>
		<key>YAYBOT_HOME</key><string>$YB_HOME</string>
		<key>LANG</key><string>en_US.UTF-8</string>
	</dict>
	<key>StandardErrorPath</key><string>$YB_HOME/boot.log</string>
</dict>
</plist>
EOF
		plutil -lint "$plist" >/dev/null 2>&1 || die "The LaunchAgent file is not valid: $plist"
		launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1
		# register it (RunAtLoad also runs it once now: harmless — it does nothing when YayBot is already running)
		if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load -w "$plist" 2>/dev/null; then
			ok "Autostart on: when you log in to this Mac, YayBot starts again by itself (if it was running) and resumes the unfinished tickets"
			say "  file: $plist · log: $YB_HOME/boot.log"
			say "  At login a Terminal window opens in the background and runs: $YB_HOME/boot.command"
			say "  Test it now (safe): open $YB_HOME/boot.command"
			say "  Tip: let the Mac restart after a power failure: sudo pmset -a autorestart 1 (you still need to log in)"
		else
			die "launchctl could not load $plist"
		fi ;;
	off)
		launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || launchctl unload -w "$plist" >/dev/null 2>&1
		rm -f "$plist" "$YB_HOME/boot.command"; ok "Autostart off" ;;
	*)
		if [ -f "$plist" ] && launchctl list 2>/dev/null | grep -q "$AGENT_ID"; then ok "Autostart on ($plist)"
		elif [ -f "$plist" ]; then warn "Autostart file exists but is not loaded: yb autostart on"
		else say "Autostart off — turn it on: yb autostart on"; fi ;;
	esac
}

# ---- yb try: take the newest ticket now and open its session (to see it working) ----
cmd_try() {
	need; need_token; st_init; need_plugins; lock
	local since ch msg ts user text pm best="" bts=0 key cls
	since=$(to_epoch "${1:-$LOOKBACK_DAYS}")
	say "Looking for the newest $PLUGIN ticket since $(fmt_date "$since" '+%Y-%m-%d')…"
	for ch in $CHANNELS; do
		while IFS= read -r msg; do
			ts=$(jq -r .ts <<<"$msg"); text=$(jq -r '.text // ""' <<<"$msg")
			[ -n "$(plugin_match "$ch" "$text")" ] || continue
			if [ "${ts%.*}" -gt "$bts" ]; then bts=${ts%.*}; best=$(jq -c --arg c "$ch" '. + {channel: $c}' <<<"$msg"); fi
		done < <(history "$ch" "$since.000000")
	done
	[ -n "$best" ] || die "No $PLUGIN ticket found in your channels since $(fmt_date "$since" '+%Y-%m-%d'). Look further back: yb try 30"
	ch=$(jq -r .channel <<<"$best"); ts=$(jq -r .ts <<<"$best"); user=$(jq -r '.user // "?"' <<<"$best"); text=$(jq -r '.text // ""' <<<"$best")
	key="$ch:$ts"
	if [ "$(jq -r --arg k "$key" '.tickets[$k].status // ""' "$STATE")" = session ]; then
		say "This ticket is already open in session $(jq -r --arg k "$key" '.tickets[$k].id' "$STATE") — see: yb sessions"; return 0
	fi
	pm=$(plugin_match "$ch" "$text"); cls=$(classify "$text" "$PLUGIN")
	say "Ticket: $(ticket_label "$ch" "$ts" "$user" "$text" "${cls%%|*}" "${pm%%|*}")"
	st_update --arg k "$key" --arg c "$ch" --arg t "$ts" --arg u "$user" --arg x "$text" --arg tag "${cls%%|*}" --arg r "${cls#*|}" --arg w "${pm#*|}" --arg p "${pm%%|*}" \
		'del(.seen[$k]) | .tickets[$k] = {channel:$c, ts:$t, user:$u, text:$x, plugin:$p, tag:$tag, tag_reason:$r, why:$w, status:"new", at:now}'
	cmd_work
	say ""; say "Open the ${c_b}Claude${c_0} app on your phone → Code → the session above. On this Mac: ${c_b}yb sessions${c_0} · problems: ${c_b}yb doctor${c_0}"
}

# ---- yb doctor: why are tickets not processed / sessions not on the phone? ----------
cmd_doctor() {
	need; st_init
	local v d s
	say "${c_b}YayBot doctor${c_0} — device: $DEVICE"
	say ""; say "${c_b}Config${c_0} ($CONF)"
	[ -n "$SLACK_BOT_TOKEN" ] && ok "Slack token set" || warn "No Slack token: yb setup xoxb-…"
	[ -n "$PLUGIN" ] && ok "Plugin: $PLUGIN" || warn "No plugin: yb plugin <Name>"
	[ -n "$MY_SLACK_ID" ] && ok "You on Slack: $(user_name "$MY_SLACK_ID") — private drafts go to you" || warn "No Slack member ID: yb slack"
	[ -n "$CHANNELS" ] && ok "Channels:$(for c in $CHANNELS; do printf ' #%s' "$(channel_name "$c")"; done)" || warn "No channels: yb channels"
	if [ -n "$SLACK_BOT_TOKEN" ]; then check_scopes "$(api auth.test 2>/dev/null | jq -r '.bot_id // ""')"; fi

	say ""; say "${c_b}Claude Code${c_0}"
	if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
		v=$("$CLAUDE_BIN" --version 2>/dev/null | head -1); ok "claude: ${v:-?} ($(command -v "$CLAUDE_BIN"))"
		[ "$(perm_mode)" = dontAsk ] && ok "Ticket sessions never wait for approval (permission mode dontAsk)" \
			|| warn "This Claude Code has no \"dontAsk\" mode: sessions may wait for your approval → run: claude update"
		"$CLAUDE_BIN" --help 2>&1 | grep -q -- '--remote-control' && ok "supports --remote-control" \
			|| warn "this claude has no --remote-control option → run: claude update"
	else warn "claude command not found"; fi
	command -v tmux >/dev/null 2>&1 && ok "tmux $(tmux -V 2>/dev/null | cut -d' ' -f2)" || warn "tmux missing: brew install tmux"
	[ "$(command -v yb 2>/dev/null)" ] && ok "yb command: $(command -v yb)" || say "  (yb is not installed as a command; the YayBot session uses $SELF)"
	d=$(cd "$YB_HOME" && pwd -P)
	[ "$(jq -r --arg d "$d" '.projects[$d].hasTrustDialogAccepted // false' "$HOME/.claude.json" 2>/dev/null)" = true ] \
		&& ok "Folder $d is trusted by Claude Code" || warn "Folder $d is not trusted yet (yb start / yb try trust it)"
	[ "$(jq -r '(.agentPushNotifEnabled == true) and (.inputNeededNotifEnabled == true)' "$HOME/.claude/settings.json" 2>/dev/null)" = true ] \
		&& ok "Push notifications on" || warn "Push notifications off: yb ping"

	say ""; say "${c_b}Tickets${c_0}"
	jq -r '"  in queue: \(.tickets | length) (" + ([.tickets[] | .status] | group_by(.) | map("\(.[0]) \(length)") | join(", ")) + ") · already reported (skipped for 7 days): \(.seen | length)"' "$STATE"
	say "  Look for tickets without processing: yb scan 30 · process the newest one now: yb try"

	say ""; say "${c_b}Sessions${c_0}"
	[ "$(uname -s)" = Darwin ] && { [ -f "$HOME/Library/LaunchAgents/$AGENT_ID.plist" ] && ok "Autostart on (YayBot comes back after a restart)" || warn "Autostart off: yb autostart on"; }
	tmux has-session -t =yb-watch 2>/dev/null && ok "Watchdog on (restarts the main session; keeps the Mac awake)" || warn "Watchdog off: yb start"
	if command -v tmux >/dev/null 2>&1 && tmux has-session -t yaybot 2>/dev/null; then
		ok "Main session \"$RC_LABEL\" is running — last lines:"; pane_tail yaybot 12 | sed 's/^/    │ /'
	else warn "Main session \"$RC_LABEL\" is not running: yb start"; fi
	for s in $(tmux ls -F '#S' 2>/dev/null | grep '^yb-'); do
		say "  ${c_b}$s${c_0} ($(sess_state "$s")) — last lines:"; pane_tail "$s" 6 | sed 's/^/    │ /'
	done
	say ""; say "${c_b}Log${c_0} (last 12 lines of $LOG)"; tail -n 12 "$LOG" 2>/dev/null | sed 's/^/    /'
}

# Turn on Claude Code push notifications (settings "Push when Claude decides" + "Push when actions required")
enable_push() {
	local f="$HOME/.claude/settings.json" tmp
	mkdir -p "$HOME/.claude"; [ -s "$f" ] || echo '{}' > "$f"
	if [ "$(jq -r '(.agentPushNotifEnabled == true) and (.inputNeededNotifEnabled == true)' "$f" 2>/dev/null)" = true ]; then
		ok "Phone push notifications are on (Claude Code settings)"; return 0
	fi
	tmp=$(mktemp) && jq '.agentPushNotifEnabled = true | .inputNeededNotifEnabled = true' "$f" > "$tmp" 2>/dev/null \
		&& cp "$f" "$f.bak-yaybot" && mv "$tmp" "$f" \
		&& ok "Turned on phone push notifications in $f (backup: settings.json.bak-yaybot)" \
		|| { rm -f "$tmp"; warn "Could not edit $f — in Claude Code type /config and turn on \"Push when Claude decides\" and \"Push when actions required\""; }
}

# Test: open a tiny Remote Control session that sends one push notification
cmd_ping() {
	command -v tmux >/dev/null 2>&1 || die "tmux is required: brew install tmux"
	command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "Claude Code (the claude command) is required"
	enable_push
	tmux kill-session -t "=yb-ping" 2>/dev/null
	trust_dir "$YB_HOME"
	env -u TMUX tmux new-session -d -s yb-ping -c "$YB_HOME" bash -c "$KEEP" yaybot env -u YAYBOT_IN_RC "$CLAUDE_BIN" \
		"This is a YayBot test. Send a push notification to my phone now (PushNotification tool) with the text: \"✅ YayBot test — notifications work\". Then reply with one line: sent." \
		--remote-control "YayBot test · $DEVICE" || die "Could not start tmux"
	( sleep 300; tmux kill-session -t "=yb-ping" ) >/dev/null 2>&1 &
	ok "Opened the test session \"YayBot test\"; a notification should reach your phone within ~30 s."
	say "  If nothing arrives: open the Claude app once (refreshes the push token), allow notifications for Claude"
	say "  in the phone settings, check Focus / Do Not Disturb, then run ${c_b}yb ping${c_0} again."
	say "  To see the session on this Mac: ${c_b}tmux attach -t yb-ping${c_0} (first time: answer the folder-trust question)."
}

cmd_sessions() {
	st_init
	local id name tst state any=0 age
	for id in $(tmux ls -F '#S' 2>/dev/null | sed -n 's/^yb-\(T[0-9]*\)$/\1/p' | sort -t T -k2 -n); do
		any=1
		name=$(jq -r --arg i "$id" '.sessions[$i].name // $i' "$STATE")
		tst=$(jq -r --arg i "$id" '(.tickets | to_entries | map(select(.value.id == $i)) | .[0].value) as $t
			| if $t == null then "reported" elif $t.status == "session" then "working" else ($t.outcome // $t.status) end' "$STATE")
		age=$(jq -r --arg i "$id" '.sessions[$i].started // empty | (now - .) / 60 | floor' "$STATE")
		case "$(sess_state "yb-$id")" in
			trust)    state="⚠ waiting: trust question (tmux attach -t yb-$id)" ;;
			exited*)  state="✗ claude stopped — $(sess_state "yb-$id" | cut -c9- | cut -c1-60)" ;;
			*) if claude_alive "yb-$id"; then
				case "$tst" in working) state="⏳ working${age:+ (${age} min)}" ;; *) state="💬 open for questions" ;; esac
			   else state="✗ claude not running"; fi ;;
		esac
		printf '  %-48s %-14s %s\n' "$name" "$tst" "$state"
	done
	[ $any = 1 ] || say "No ticket sessions are open."
	[ $any = 1 ] && say "  (on this Mac: tmux attach -t yb-T7 · close finished ones: yb cleanup)"
	return 0
}

# Close finished ticket sessions and remove their git worktrees
cmd_cleanup() {
	st_init
	local id s act wt n=0 list="" ans
	act=" $(active_ids | tr '\n' ' ') "
	for s in $(tmux ls -F '#S' 2>/dev/null | grep '^yb-T'); do
		id=${s#yb-}
		case "$act" in *" $id "*) claude_alive "$s" && continue ;; esac   # still working → keep
		list="$list $id"
	done
	if [ -n "$list" ]; then
		say "Finished ticket sessions:$list"
		if [ -t 0 ] && [ "$1" != "-y" ]; then printf 'Close them? [Y/n] '; read -r ans; case "$ans" in [nN]*) list="" ;; esac; fi
		for id in $list; do
			tmux kill-session -t "=yb-$id" 2>/dev/null && n=$((n + 1)); logf "cleanup: closed yb-$id"
			st_update --arg i "$id" '.tickets |= map_values(if .id == $i then .closed_by_user = true else . end)'
			st_update --arg i "$id" '.sessions[$i].done_at = (.sessions[$i].done_at // now)'
		done
		[ $n -gt 0 ] && ok "Closed $n session(s)"
	else
		say "No finished ticket sessions."
	fi
	# worktrees of tickets that are no longer being worked on
	for wt in "$YB_HOME"/worktrees/T*; do
		[ -d "$wt" ] || continue
		id=$(basename "$wt"); case "$act" in *" $id "*) continue ;; esac
		remove_worktree "$wt" && ok "Removed worktree $id"
	done
	ls "$YB_HOME"/results/T*.json >/dev/null 2>&1 && for wt in "$YB_HOME"/results/T*.json; do
		id=$(basename "$wt" .json); case "$act" in *" $id "*) ;; *) tmux has-session -t "=yb-$id" 2>/dev/null || rm -f "$wt" ;; esac
	done
	return 0
}

cmd_close() {
	case "$1" in
		"") die "Usage: yb close T7 | yb close all" ;;
		all) for id in $(tmux ls -F '#S' 2>/dev/null | grep '^yb-T'); do tmux kill-session -t "=$id"
		        [ "$2" = keep ] || st_update --arg i "${id#yb-}" '.tickets |= map_values(if .id == $i then .closed_by_user = true else . end)'; done
		     ok "Closed all ticket sessions" ;;
		*) tmux kill-session -t "=yb-$1" 2>/dev/null && ok "Closed session $1" || die "No open session $1 (see: yb sessions)"
		   st_update --arg i "$1" '.tickets |= map_values(if .id == $i then .closed_by_user = true else . end)' ;;
	esac
}

# The command the Remote Control session runs: "yb" when it is installed, else this script's full path
yb_cmd() { if [ "$(command -v yb 2>/dev/null)" ]; then echo yb; else echo "$SELF"; fi; }

# Instruction for the Claude Remote Control session: run `yb run` periodically, show the report, push a notification.
rc_prompt() {
	printf '/loop %s Run the command `%s run` (Bash, timeout 600000). Keep every answer SHORT — the user reads it on a phone. If the output has no line starting with "📋", answer with one short line (e.g. "No new tickets." or "2 tickets being worked on.") and do NOT send a notification. Otherwise show only the lines from each "📋" line to the end of that report, exactly as they are (no extra text), then call the PushNotification tool with the "📋" line only. Details are in the ticket sessions (T1, T2…); give more only when asked. Never post anything to Slack.' "$RC_EVERY" "$(yb_cmd)"
}

# Claude Remote Control session "YayBot" running in the background in tmux → open it on your phone (Claude app).
cmd_start() {
	need; need_token; st_init
	command -v tmux >/dev/null 2>&1 || die "tmux is required: brew install tmux"
	command -v "$CLAUDE_BIN" >/dev/null 2>&1 || die "Claude Code (the claude command) is required"
	enable_push
	touch "$YB_HOME/.running"
	if tmux has-session -t yaybot 2>/dev/null; then
		if claude_alive yaybot || [ "$(sess_state yaybot)" = trust ]; then
			start_watch
			ok "The YayBot session is already running. Phone: Claude app → session \"$RC_LABEL\". On this Mac: yb attach"
			return
		fi
		warn "The YayBot session had stopped ($(sess_state yaybot | cut -c9- | cut -c1-80)) — restarting it"
		tmux kill-session -t =yaybot 2>/dev/null
	fi
	trust_dir "$YB_HOME"
	env -u TMUX tmux new-session -d -s yaybot -c "$YB_HOME" bash -c "$KEEP" yaybot \
		env YAYBOT_IN_RC=1 "$CLAUDE_BIN" "$(rc_prompt)" --allowedTools "Bash($(yb_cmd) run)" "Bash($(yb_cmd) run:*)" "Bash($(yb_cmd) scan:*)" "Bash($(yb_cmd) status)" "Bash($(yb_cmd) report)" --remote-control "$RC_LABEL" \
		|| die "Could not start tmux"
	sleep "${YAYBOT_START_WAIT:-6}"
	case "$(sess_state yaybot)" in
		exited*) die "Claude stopped right away: $(sess_state yaybot | cut -c9-) — see: yb doctor" ;;
		trust) warn "The session waits for \"Do you trust this folder?\": run yb attach, choose Yes, then Ctrl+B D" ;;
	esac
	start_watch
	ok "Started the Claude Remote Control session \"$RC_LABEL\" (in the background, in tmux); it runs \`yb run\` every $RC_EVERY."
	say "  • Phone: open the Claude app → session \"$RC_LABEL\" for the summary reports; every ticket also gets its own"
	say "    session (\"T7 · major · #channel · person\") that pushes its result to your phone."
	say "  • Test now with one ticket: ${c_b}yb try${c_0} · something wrong: ${c_b}yb doctor${c_0}"
}
cmd_stop() {
	rm -f "$YB_HOME/.running"
	tmux kill-session -t =yb-watch 2>/dev/null && ok "Stopped the watchdog (the Mac may sleep again)"
	if tmux has-session -t yaybot 2>/dev/null; then tmux kill-session -t yaybot && ok "Stopped the YayBot session"; else say "No YayBot session is running"; fi
}

# Background helper (tmux session "yb-watch"): keeps the Mac awake and restarts the main
# session when Claude stopped (at most 3 times per hour, then it gives up and logs why).
start_watch() {
	tmux has-session -t =yb-watch 2>/dev/null && return 0
	env -u TMUX tmux new-session -d -s yb-watch -c "$YB_HOME" "$SELF" watch 2>/dev/null \
		&& logf "watchdog started" || warn "Could not start the watchdog"
}
cmd_watch() {
	local restarts="" now t
	c_g=; c_r=; c_y=; c_b=; c_0=
	if [ "$KEEP_AWAKE" = 1 ] && command -v caffeinate >/dev/null 2>&1; then
		caffeinate -i -w $$ & say "Keeping the Mac awake (caffeinate) while YayBot runs."
	fi
	say "YayBot watchdog: checks the main session every ${WATCH_EVERY}s. Stop with: yb stop"
	while sleep "$WATCH_EVERY" && [ -f "$YB_HOME/.running" ]; do
		if ! tmux has-session -t =yaybot 2>/dev/null || { ! claude_alive yaybot && [ "$(sess_state yaybot)" != trust ]; }; then
			now=$(date +%s); t=""
			for t0 in $restarts; do [ $((now - t0)) -lt 3600 ] && t="$t $t0"; done; restarts=$t
			if [ "$(printf '%s\n' $restarts | grep -c .)" -ge 3 ]; then
				logf "watchdog: main session stopped again — not restarting (3 restarts in the last hour). See: yb doctor"
				say "$(date '+%H:%M') main session keeps stopping — not restarting. See: yb doctor"
			else
				logf "watchdog: main session stopped ($(sess_state yaybot 2>/dev/null | cut -c9- | cut -c1-80)) — restarting"
				say "$(date '+%H:%M') main session stopped — restarting"
				tmux kill-session -t =yaybot 2>/dev/null
				( YAYBOT_START_WAIT=10 cmd_start ) >>"$LOG" 2>&1
				restarts="$restarts $now"
			fi
		fi
	done
	say "YayBot stopped — watchdog exits."
}
cmd_attach() { tmux attach -t yaybot 2>/dev/null || die "Not running. Type: yb start"; }
cmd_status() {
	st_init
	local running="✗ not running (yb start)" last
	if command -v tmux >/dev/null 2>&1 && tmux has-session -t yaybot 2>/dev/null; then
		if claude_alive yaybot; then running="✓ running (Remote Control session \"$RC_LABEL\", every $RC_EVERY)"
		elif [ "$(sess_state yaybot)" = trust ]; then running="⚠ waiting for the folder-trust question (yb attach)"
		else running="✗ claude stopped — $(sess_state yaybot | cut -c9- | cut -c1-60)"; fi
	fi
	say "Device:       $DEVICE (change: yb device <name>)"
	say "Main session: $running"
	if tmux has-session -t =yb-watch 2>/dev/null; then
		say "Watchdog:     ✓ on (auto-restart$( [ "$KEEP_AWAKE" = 1 ] && command -v caffeinate >/dev/null 2>&1 && printf ', Mac kept awake'))"
	else say "Watchdog:     ✗ off (yb start turns it on)"; fi
	case "$(uname -s)" in Darwin)
		if [ -f "$HOME/Library/LaunchAgents/$AGENT_ID.plist" ]; then say "Autostart:    ✓ on (after login)"; else say "Autostart:    ✗ off (yb autostart on)"; fi ;; esac
	[ -f "$YB_HOME/boot.log" ] && say "Last boot:    $(grep -h 'YayBot boot on' "$YB_HOME/boot.log" | tail -1 | cut -c1-19)"
	say "Config:       $CONF"
	say "Ticket sessions:"; cmd_sessions
	jq -r '"Tickets in queue: \(.tickets | length)",
		(.tickets[] | "  [\(.tag)] \(.status)\(if .outcome then " → " + .outcome else "" end) — \(.text | gsub("<[^>]*>"; "") | gsub("\\s+"; " ") | .[0:80])")' "$STATE"
	last=$(ls -1t "$YB_HOME/reports/"*.md 2>/dev/null | head -1)
	[ -n "$last" ] && say "Latest report: $last"
	return 0
}

cmd_install() {
	local dir
	for dir in /usr/local/bin "$HOME/.local/bin"; do
		if [ -w "$dir" ] || mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
			ln -sf "$SELF" "$dir/yb" && chmod +x "$SELF" && ok "Installed: $dir/yb → type ${c_b}yb help${c_0}"
			case ":$PATH:" in *":$dir:"*) ;; *) warn "Add to ~/.zshrc: export PATH=\"$dir:\$PATH\"";; esac
			return
		fi
	done
	die "Cannot write to /usr/local/bin or ~/.local/bin"
}

cmd_manifest() {
	# Scopes: read the channels + users, join public channels, write (thread replies + reports).
	local m='{"display_information":{"name":"YayBot","description":"Reads plugin support tickets and replies in their threads, visible only to you"},"features":{"bot_user":{"display_name":"YayBot","always_online":false}},"oauth_config":{"scopes":{"bot":["channels:history","channels:read","channels:join","groups:history","groups:read","users:read","chat:write"]}},"settings":{"org_deploy_enabled":false,"socket_mode_enabled":false,"token_rotation_enabled":false}}'
	printf '%s\n' "$m"
	command -v pbcopy >/dev/null 2>&1 && printf '%s' "$m" | pbcopy && ok "Manifest copied to the clipboard"
}

cmd_help() { sed -n '3,/^# =====/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'; }

case "${1:-help}" in
	setup)    shift; cmd_setup "$@" ;;
	check)    cmd_check ;;
	scan)     shift; cmd_scan "$@" ;;
	plugin|plugins) shift; if [ $# -gt 0 ]; then cmd_plugin "$@"; else need; st_init; cmd_plugin_show; fi ;;
	channels) shift; [ -n "$PLUGIN" ] || die "Choose the plugin first: yb plugin <Name>"
	          if [ $# -gt 0 ]; then cmd_plugin "$PLUGIN" "$@"; else [ -t 0 ] || die "Usage: yb channels #channel1 #channel2"; cmd_plugin "$PLUGIN" --pick; fi ;;
	run)      cmd_run ;;
	start)    cmd_start ;;
	stop)     cmd_stop; [ "$2" = all ] && cmd_close all keep ;;
	sessions) cmd_sessions ;;
	cleanup)  shift; cmd_cleanup "$@" ;;
	watch)    cmd_watch ;;
	try)      shift; cmd_try "$@" ;;
	boot)     cmd_boot ;;
	autostart) shift; cmd_autostart "$@" ;;
	device)   shift
	          if [ -z "$1" ]; then say "This computer is: $DEVICE  (sessions: \"$RC_LABEL\", \"T7 · … · $DEVICE\")"; say "Change it: yb device <name>   e.g. yb device work"
	          else st_init; n=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-24)
	               [ -n "$n" ] || die "Invalid name"; conf_set DEVICE "$n"; ok "This computer is now: $n"
	               say "Restart to rename the sessions: yb stop all && yb start"; fi ;;
	rescan)   shift; need; need_token; st_init
	          case "${1:-}" in ''|*[!0-9]*) ;; *) LOOKBACK_DAYS=$1 ;; esac
	          st_update '.cursor = {}'; ok "Reading the channels again from $(fmt_date "$(to_epoch "")" '+%Y-%m-%d') (tickets already reported are skipped)"; cmd_run ;;
	collect)  need; need_token; st_init; lock; collect_sessions; cmd_report ;;
	slack)    shift; cmd_slack "$@" ;;
	doctor)   cmd_doctor ;;
	close)    shift; cmd_close "$@" ;;
	ping)     need; st_init; cmd_ping ;;
	attach)   cmd_attach ;;
	status)   cmd_status ;;
	log)      touch "$LOG"; tail -n 50 -f "$LOG" ;;
	report)   need; need_token; st_init; lock; before=$(latest_report); cmd_report force
	          [ "$YAYBOT_IN_RC" = 1 ] || { [ "$(latest_report)" != "$before" ] && notify_rc; } ;;
	install)  cmd_install ;;
	manifest) cmd_manifest ;;
	reset)    rm -f "$STATE"; ok "Temporary data deleted (config kept)" ;;
	*)        cmd_help ;;
esac
