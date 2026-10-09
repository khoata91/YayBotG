# YayBot

YayBot watches the Slack support channels of **one plugin you choose** (e.g. YayExtra) and lets **Claude** work on every ticket:

1. It reads new messages in the channels you pick and keeps the ones about the plugin.
2. It sorts each ticket into one type: `how-to` · `trivial` · `technical` · `major` · `fatal`.
3. It opens **one Claude session per ticket** (e.g. `T7 · YayExtra · major · Anna`). You can open these sessions in the Claude app on your phone.
4. It replies **in the ticket's Slack thread, visible only to you**:
   - ✅ **Claude handled it** (`how-to` answered, or `trivial` fixed with a PR): Claude's suggested reply, ready for you to send.
   - 🧑‍💻 **You need to fix it** (`technical`, `major`, `fatal`, or Claude is unsure): the cause and a suggested fix. Claude does not fix it and does not answer the customer.
5. It sends a short notification to your phone.

YayBot writes nowhere else in Slack. Everything is done with one command, `yb <task>`, and there is no database. Config and temporary data live in `~/.yaybot`.

---

## Quick start

| Step | Command |
|---|---|
| 0. Install the `yb` command (once) | `./yaybot.sh install` |
| 0. Log Claude Code in to your claude.ai account (once) | `claude` → `/login` |
| 1. Create the Slack app (once) | `./yaybot.sh manifest`, then a few clicks |
| 2. Set up: token, plugin, channels, you | `yb setup xoxb-…` |
| 3. Look at the tickets (changes nothing) | `yb scan` |
| 4. Test phone notifications | `yb ping` |
| 5. Start | `yb start` |
| 6. Process the newest ticket right now | `yb try` |



## 0. Requirements

- A Mac (or Linux) with Terminal, switched on while YayBot runs. YayBot keeps it awake by itself; a closed lid can still put a MacBook to sleep.
- [Claude Code](https://docs.claude.com/en/docs/claude-code), logged in with your **claude.ai** account. Run `claude update` to get the latest version.
- The **Claude** app on your phone, logged in with the same account, with notifications allowed. Open it once so it registers for notifications.
- `jq` and `tmux`: `brew install jq tmux`.

From the YayBot folder, run `./yaybot.sh install`. If it prints an `Add to ~/.zshrc …` line, add that line to `~/.zshrc` and open a new Terminal.

---

## 1. Create the Slack app (once)

```bash
./yaybot.sh manifest      # prints the manifest and copies it to the clipboard
```

1. Open <https://api.slack.com/apps>, then **Create New App** → **From an app manifest**.
2. Pick your workspace, paste the manifest, then **Next** → **Create**.
3. **Install to Workspace** → **Allow**.
4. Under **OAuth & Permissions**, copy the **Bot User OAuth Token** (`xoxb-…`).

The app gets these permissions (scopes):

- `channels:history`, `channels:read`, `groups:history`, `groups:read`: read the channels.
- `channels:join`: join the public channels it reads.
- `users:read`: show people's real names.
- `chat:write`: post the replies in ticket threads.

**Already have the app?** Add any missing scope under *OAuth & Permissions → **Bot Token Scopes***, click **Reinstall to Workspace**, then run `yb check`.

---

## 2. Set up: `yb setup xoxb-…`

Keep the YayBot folder inside `wp-content/plugins`, then run `yb setup xoxb-…`. It saves the config (`~/.yaybot/config`, permissions 600), checks the token, `claude` and `tmux`, turns on push notifications, and then asks you three things:

```
Which plugin should YayBot support? (e.g. YayExtra): YayExtra

1. Source code (in …/wp-content/plugins)
✓ Found YayExtra: …/wp-content/plugins/yayextra
✓ It is a git repo: Claude may fix `trivial` tickets in a separate worktree and open a PR
  Docs list: …/YayBot/docs.md
✓ Docs: https://docs.yaycommerce.com/yayextra

2. Keywords used to recognise YayExtra tickets: YayExtra, add-on, conditional field, extra product option

Slack channels YayBot can see (6):
    1. #random
    2. #support-guabin
    3. #support-yayextra
    …
Channels for YayExtra: 2 3

  ✓ #support-guabin — shared channel: only messages about YayExtra are tickets (7 of 120 message(s))
  ✓ #support-yayextra — only about YayExtra: every message is a ticket (24 message(s))

Your Slack name or member ID: Khoa
✓ Test message posted in #support-guabin — only you can see it
```

- **Plugin and source code.** YayBot looks in the plugins folder for this plugin, by folder name or by the `Plugin Name:` header. If it finds the code, Claude reads it. If not, Claude relies on its own knowledge. If your code is in another folder, run `yb setup xoxb-… <folder>`.
- **Docs (`docs.md`).** Put the documentation links in `docs.md`, in the YayBot folder next to `yaybot.sh`, one link per plugin:

  ```markdown
  - YayExtra: https://docs.yaycommerce.com/yayextra
  - YayCurrency: https://docs.yaycommerce.com/yaycurrency
  ```

  YayBot gives Claude the links on the lines that mention the plugin. Claude opens them and follows them to the guide that matches the ticket. If `docs.md` has no line for the plugin, YayBot uses `https://docs.yaycommerce.com/<plugin>` plus the documentation links listed in `docs.md`. YayBot checks that each link opens.
- **Keywords.** Claude suggests the words customers use for this plugin, so a ticket is recognised even when its name is not written.
- **Channels: you pick them.** Type numbers, names, channel links or IDs.
  - In a **shared** channel, only messages about the plugin count as tickets.
  - In a channel **named after the plugin**, or one you mark with `:all` (e.g. `2:all`), every message counts as a ticket.
  - A **private** channel only appears in the list after you type `/invite @YayBot` in it. To read a public channel, YayBot joins it, so Slack shows one "YayBot joined" line there.
- **You.** Give your Slack name or member ID (your profile → ⋮ → *Copy member ID*). Thread replies are visible only to this person.

Change things later:

```bash
yb plugin                 # show the plugin, its source folder, keywords and channels
yb plugin YayPricing      # switch to another plugin (asks for its channels)
yb channels               # pick the channels again (Enter keeps the current ones)
yb channels #support-guabin #support-yayextra:all
yb slack                  # change who receives the private replies
```

To change the keywords yourself, edit `~/.yaybot/plugins.json` and add `"edited": true` so YayBot keeps your version.

---

## 3. Look at the tickets: `yb scan`

This only reads and lists; it creates nothing.

```bash
yb scan                   # last 7 days   ·   yb scan 30   ·   yb scan 2026-10-01
```

```
 1. [YayExtra · major] #support-guabin · 2026-10-06 11:03 · Anna Nguyen
    the extra option fee is not added for variable products
    ↳ plugin because of keyword "extra product option" · type because claude: fee missing from the cart total
 2. [YayExtra · how-to] #support-yayextra · 2026-10-06 10:12 · Eva
    ↳ plugin because of channel · …

Total: 2 YayExtra ticket(s) (5 other message(s) skipped)
  how-to 1 · trivial 0 · technical 0 · major 1 · fatal 0
```

---

## 4. Run: `yb start`

```bash
yb ping       # test: a session "YayBot test" sends you one notification
yb start      # start YayBot in the background
yb try        # don't wait: process the newest ticket now (yb try 30 = look back 30 days)
```

`yb start` opens the main session **"YayBot"** (Claude Code with Remote Control, inside `tmux`). Every **10 minutes** it runs `yb run`, which:

1. fetches new messages from your channels and keeps the plugin's tickets;
2. classifies each ticket;
3. opens a **new session for each ticket**, which you can see in the Claude app. In that session, Claude reads the plugin's code (read-only) and the docs from `docs.md`, and works on the ticket **without waiting for your approval**:

   | Type | Example | What Claude does |
   |---|---|---|
   | `how-to` | "How do I show the option price?" | checks the **code and the docs**, finds the matching guide, and writes the reply for the customer with the exact menu names and the guide's link |
   | `trivial` | typo, CSS, symbol position | checks the **code and the docs**, then fixes the code and **opens a PR** (only if the plugin folder is a git repo). It works in a separate git worktree under `~/.yaybot/worktrees/` and never touches your checkout, never merges and never deploys |
   | `technical` | plugin/cache conflict, behaviour differs from the docs | finds the cause and suggests a fix |
   | `major` | wrong price, fee or currency in cart/checkout | finds the cause and suggests a fix |
   | `fatal` | white screen, fatal error, 500 | finds the cause and suggests a fix |

4. As soon as Claude finishes, YayBot posts the result **in the ticket's thread, visible only to you**, and sends a notification to your phone.

`yb start` also starts a small **watchdog** (tmux session `yb-watch`) that:

- **keeps the Mac awake** (`caffeinate`) while YayBot runs;
- checks the main session every minute and **restarts it if Claude stopped**. If it stops 3 times within an hour, the watchdog gives up and writes the reason to the log; then see `yb doctor`.

`yb stop` turns both off.

Limits: at most **5** ticket sessions run at once (the rest start on the next run). A ticket with no result after **2 hours** goes under "you need to fix". Finished sessions close after **24 hours**.

**Several computers?** Every name shows which computer is working, so you can tell them apart on your phone:

- the main session: `YayBot · work-mac`;
- each ticket session: `T7 · YayCurrency · major · Anna · work-mac`;
- every log line: `[2026-10-08 09:12:03] [work-mac] …`.

The name defaults to the computer's host name. Change it with `yb device work`, then `yb stop all && yb start`. Note that two computers running YayBot on the same channels still both process the same tickets.

**When the Mac is switched off or loses power:**

```bash
yb autostart on      # once: YayBot comes back by itself when you log in to the Mac
```

At the next login, macOS opens a Terminal window in the background that runs `yb boot`, which:

1. waits until Slack is reachable;
2. clears what the shutdown left behind (old lock, tickets marked as being worked on);
3. starts YayBot again (main session, watchdog, Mac kept awake);
4. **resumes the unfinished ticket sessions** with `claude --resume`. Claude continues the same conversation, so its previous analysis is not lost. If the conversation is missing, the ticket is started again with the same number. Each ticket is resumed at most 2 times (`MAX_RESUMES`); after that it goes under 🧑‍💻;
5. fetches the tickets that arrived while the Mac was off.

This only happens if YayBot was running when the Mac went off: after `yb stop`, it stays off. A session that you closed yourself (`yb close T7`, `yb cleanup`) is never resumed. If Claude stops in the middle of a ticket while the Mac is running, the ticket is resumed in the same way. To let the Mac switch itself back on after a power failure: `sudo pmset -a autorestart 1`. You still need to log in; with FileVault, macOS cannot log in by itself. Turn autostart off with `yb autostart off`; its log is `~/.yaybot/boot.log`.

**First time only:** run `yb attach`. If Claude asks *"Do you trust the files in this folder?"*, choose **Yes**, then press **Ctrl+B, then D** to leave it running. YayBot normally marks this folder as trusted for you.

---

## 5. What you see

**In the Slack thread of each ticket** (only you can see it):

```
🧑‍💻 YayBot T7 · major · needs you · only you can see this
Extra option fee is missing for variable products.
Cause: the fee hook runs before the variation price is set.
Suggested fix: recalculate the fee in woocommerce_before_calculate_totals.
```

```
✅ YayBot T9 · how-to · only you can see this
Suggested reply:
Hi! Go to YayExtra → Settings → Display and enable "Show option price"…
```

> Slack does not keep "only visible to you" messages: they disappear when you reload Slack or switch device. The same result stays in the ticket's session and in `~/.yaybot/reports/`.

**On this Mac:** `yb sessions` shows the state of each ticket session:

```
  T7 · YayCurrency · major · Anna      working     ⏳ working (6 min)
  T8 · YayCurrency · how-to · Eva      reported    💬 open for questions
  T9 · YayCurrency · major · Dung      needs_user  ✗ claude stopped — …
```

`yb cleanup` closes the finished sessions and removes their git worktrees in `~/.yaybot/worktrees` (a worktree with uncommitted changes is kept). Finished sessions are also closed automatically after 24 hours.

**On your phone (Claude app):**

- Each ticket session shows 3 short lines (result, cause, fix or answer) and sends a one-line notification. You can still ask Claude in the session for the full analysis or the message to send the customer.
- The **"YayBot"** session shows one line per ticket:

  ```
  📋 YayExtra · 07/10 14:30 — 3 ticket(s): ✅ 1 · 🧑‍💻 2
  🧑‍💻 T7 major · Anna — extra option fee missing for variable products
  ✅ T9 how-to · Eva — explained how to show the option price
  ```

✅ means Claude answered, or opened a PR, with confidence ≥ 0.75. For `how-to` and `trivial` tickets, the answer must be confirmed by the code and the docs; otherwise the ticket goes to you (🧑‍💻). Full reports (Slack links, cause, fix, customer reply) are saved in `~/.yaybot/reports/`, and the last 30 are kept. Reported tickets are not picked up again for 7 days.

---

## 6. Settings (optional)

Edit `~/.yaybot/config` (`open -e ~/.yaybot/config`), then run `yb stop all && yb start`.

| Variable | Default | Meaning |
|---|---|---|
| `PLUGIN` · `CHANNELS` · `CHANNEL_PLUGINS` | set by `yb plugin` / `yb channels` | the plugin, its channels, and the channels where every message is a ticket |
| `MY_SLACK_ID` | set by `yb slack` | who sees the thread replies |
| `PLUGINS_DIR` | the folder containing YayBot | where the plugins' source code is |
| `DOCS_FILE` · `DOCS_BASE` · `PLUGIN_DOCS` | `docs.md` next to `yaybot.sh` · `https://docs.yaycommerce.com` · empty | the docs list · the docs site used when the list has no line for the plugin · one fixed docs URL that overrides both |
| `SLACK_DRAFTS` | `1` | `0` = do not post in the threads |
| `AUTO_FIX_TAGS` | `trivial` | types Claude may fix itself with a PR, e.g. `"trivial technical"` |
| `MIN_CONFIDENCE` | `0.75` | below this, the ticket goes under "you need to fix" |
| `CLASSIFIER` | `claude` | `claude` (accurate) or `rules` (keywords, fast, free) |
| `RC_EVERY` · `RC_NAME` | `10m` · `YayBot` | how often the main session runs, and its name |
| `DEVICE` | the computer's host name | this computer's name in session names and the log (`yb device <name>`) |
| `TICKET_SESSIONS` | `1` | `0` = no session per ticket; Claude works in the background |
| `MAX_SESSIONS` · `SESSION_TIMEOUT` · `KEEP_SESSIONS_HOURS` | `5` · `7200` · `24` | sessions at once · seconds before giving up · hours before closing |
| `KEEP_AWAKE` · `WATCH_EVERY` | `1` · `60` | keep the Mac awake · seconds between two checks of the main session |
| `MAX_RESUMES` | `2` | how often an interrupted ticket session is resumed |

---

## 7. Troubleshooting

**First run `yb doctor`.** It checks the config, the Slack scopes, the Claude Code version, folder trust, notifications and the ticket queue, and shows the last lines of every session.

| Problem | Fix |
|---|---|
| `invalid_auth` / `not_authed` | wrong or revoked token: `yb setup xoxb-…` |
| `missing_scope`, or "Slack channels YayBot can see (0)" | `yb check` shows which app the token belongs to (with a link), its scopes and what is missing. Add the missing ones under **Bot Token Scopes** (not *User Token Scopes*), **Reinstall to Workspace**, then run `yb setup` with the token shown there. If Slack says *Request to install*, an admin must approve first |
| A channel is missing from the list / `not_in_channel` | it is private: type `/invite @YayBot` in it, then `yb channels` |
| Names show as IDs (`U0C6…`) | add the `users:read` scope and reinstall |
| No reply in the Slack thread | `yb doctor` must say *"never wait for approval"*; if not, run `claude update`. You must be a member of the channel. The reply appears when the ticket's session finishes (`yb collect` picks up results right away) |
| No ticket processed | no new tickets since the last run (already-reported ones are skipped for 7 days): `yb try` · `yb scan 30` |
| A ticket was missed | `yb plugin` to check its channel and keywords; add the channel with `yb channels`, use `:all`, or add a keyword (with `"edited": true`). Then `yb rescan 7` reads the channels again: messages that were skipped are checked again, and tickets already reported are not repeated |
| No session on the phone | same claude.ai account on the Mac and phone; `claude update`; `yb attach` to see errors |
| A ticket session stays "working" | `tmux attach -t yb-T7` to see what it is doing (Ctrl+B, D to leave) |
| YayBot did not come back after a restart | `yb status` shows *Autostart* and the last boot; read `~/.yaybot/boot.log`. Turn it on with `yb autostart on`. You can run `yb boot` by hand at any time |
| The main session keeps stopping | `yb status` shows *claude stopped* with the reason; `yb log` shows the watchdog restarts. Run `yb doctor`, fix the cause (often `claude update` or a logged-out Claude Code), then `yb start` |
| The main session does not run every 10 minutes | `claude update` (needs `/loop`), or type in the session: "run yb run every 10 minutes" |
| No notifications on the phone | `yb ping`; open the Claude app once; allow its notifications; turn off Focus / Do Not Disturb (Android: no battery optimisation for Claude); in `claude` → `/config`, check that both push settings are on and it does not say "No mobile registered". Pushes are skipped while you type in that session on the Mac |
| `Docs: … did not answer`, or the reply has no guide link | check the links in `docs.md` (one line per plugin, with the plugin's name on the line); open them in a browser |
| Claude does not see the plugin's code | `yb setup xoxb-… <folder with the plugins>` |

---

## All commands

```
yb setup [xoxb-token] [dir]    set up: token, plugin, channels, you
yb plugin [<Name> [#ch …]]     show / change the plugin (and its channels)
yb channels [#ch …]            change the channels (no names = pick from the list; #ch:all = every message is a ticket)
yb slack [you]                 who sees the thread replies (only you)
yb check | doctor              check the connection / find out what is wrong
yb scan [7|2026-10-01]         list the plugin's tickets, changes nothing
yb start | stop [all] | attach start (+ watchdog, Mac kept awake) / stop (all = also ticket sessions) / view the main session
yb device [name]               show / set this computer's name
yb autostart [on|off]          start again by itself after the Mac restarts (resumes unfinished tickets)
yb boot                        what autostart runs (you can also run it by hand)
yb try [days]                  process the newest ticket now
yb run | collect               process once now / pick up finished ticket sessions now
yb rescan [days]               read the channels again (after changing the plugin, channels or keywords)
yb sessions | close T7|all     ticket sessions and their state (working / open / stopped) / close them
yb cleanup [-y]                close finished ticket sessions + remove their worktrees
yb report | status | log       report now / status / log
yb ping                        test the phone notification
yb reset                       delete temporary data (keeps the config)
yb manifest | install          Slack app manifest / install the yb command
```

Uninstall: `yb stop all && rm -rf ~/.yaybot`, then delete the Slack app at api.slack.com.
