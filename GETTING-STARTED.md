# YayBot: getting started

YayBot reads the support tickets of **one plugin** in the Slack channels you choose and lets **Claude** work on each ticket. The result is posted in the ticket's thread, **visible only to you**, with a notification on your phone. YayBot never answers the customer itself.

Everything is done with one command: `yb <task>`. The config lives in `~/.yaybot`.

## Setup (once)

### 1. Requirements

- A Mac or Linux computer, switched on while YayBot runs.
- [Claude Code](https://docs.claude.com/en/docs/claude-code), logged in (`claude` → `/login`).
- The **Claude** app on your phone, with the same claude.ai account and notifications allowed.

```bash
brew install jq tmux
```

```bash
claude update
```

### 2. Install the `yb` command

Put the YayBot folder **inside `wp-content/plugins`**, next to the plugin's source code, so Claude can read the code.

```bash
git clone https://github.com/khoata91/YayBot.git
```

```bash
cd YayBot && ./yaybot.sh install
```

If it prints an `Add to ~/.zshrc …` line, add that line to `~/.zshrc` and open a new Terminal.

✔ Typing `yb` shows the list of commands.

### 3. Get the Slack token

If your team already has the YayBot Slack app, ask its owner for the `xoxb-…` token. If not:

```bash
yb manifest
```

1. Open <https://api.slack.com/apps> → **Create New App** → **From an app manifest**.
2. Paste the manifest (already in your clipboard) → **Create** → **Install to Workspace**.
3. Under **OAuth & Permissions**, copy the **Bot User OAuth Token** (`xoxb-…`).

Never paste the token into Slack or commit it to git.

### 4. Set up

```bash
yb setup xoxb-YOUR-TOKEN
```

It asks three things:

| Question | Answer |
|---|---|
| Which plugin? | The plugin's name, e.g. `YayExtra` |
| Which Slack channels? | Their numbers in the list, e.g. `2 3`. Add `:all` (e.g. `2:all`) if every message in the channel is a ticket |
| Who are you on Slack? | Your Slack name or member ID |

A private channel only appears after you type `/invite @YayBot` in it.

✔ `yb check` says the token is valid; `yb plugin` shows the right plugin and channels.

### 5. Look at the tickets

```bash
yb scan
```

It only reads and lists the tickets of the last 7 days, and sends nothing. To look further back: `yb scan 30`.

### 6. Test the notification

```bash
yb ping
```

✔ Your phone gets one notification from the Claude app.

### 7. Start

```bash
yb start
```

YayBot runs in the background and fetches new tickets every 10 minutes. To process the newest ticket right now:

```bash
yb try
```

The first time, run `yb attach`. If Claude asks *"Do you trust the files in this folder?"*, choose **Yes**, then press **Ctrl+B, D** to leave.

✔ `yb status` shows the main session and the watchdog are on.

### 8. Come back after a restart

```bash
yb autostart on
```

When you log in to the Mac again, YayBot starts by itself and continues the unfinished tickets.

## Daily work

Each ticket gets one type, and Claude handles it accordingly:

| Type | Example | Result | What you do |
|---|---|---|---|
| `how-to` | "How do I show the option price?" | ✅ A suggested reply for the customer | Read it, then send it |
| `trivial` | typo, CSS | ✅ A PR with the fix | Review and merge |
| `technical` | plugin or cache conflict | 🧑‍💻 The cause and a suggested fix | Fix it yourself |
| `major` | wrong price or fee | 🧑‍💻 The cause and a suggested fix | Fix it yourself |
| `fatal` | white screen, 500 error | 🧑‍💻 The cause and a suggested fix | Fix it yourself |

A ticket Claude is unsure about also becomes 🧑‍💻.

- **Read the result** in the ticket's Slack thread. That message disappears when you reload Slack; a copy is kept in `~/.yaybot/reports/`.
- **Ask more** in the Claude app, in the ticket's session (named like `T7 · YayExtra · major · Anna`).
- **Check on things:** `yb status`, `yb sessions`.
- **Clean up finished sessions:** `yb cleanup`.
- **Stop everything:** `yb stop all`.

## Several computers (optional)

Use this when you have two computers and want the second one to continue when the first is switched off. They share the queue through a **private** git repo, and only one works at a time. Do not share the repo with another person.

On each computer, finish steps 1–7 with the same token, plugin and channels, then:

```bash
yb device computer-name
```

```bash
yb cloud https://github.com/khoata91/yaybot-state.git
```

```bash
yb start
```

Replace the URL with your own repo, in its **HTTPS** form. If it says `Cannot reach …`, the computer has no access to the repo; try `git ls-remote <url>`.

- The first computer to run `yb start` works; the other one waits on *Standby*.
- When the working computer is silent for more than 5 minutes, the standby one takes over.
- `yb stop` hands the work over at once; `yb takeover` takes it now; `yb cloud off` turns the cloud off.

## Commands

The main commands are in **bold**.

| Command | What it does |
|---|---|
| **`yb setup [token] [dir]`** | Set up the token, plugin, channels and recipient |
| **`yb scan [days]`** | List the tickets, changes nothing |
| **`yb start`** | Start in the background |
| **`yb stop [all]`** | Stop; `all` also stops the ticket sessions |
| **`yb status`** | Show the status |
| **`yb try [days]`** | Process the newest ticket now |
| **`yb sessions`** | List the ticket sessions |
| **`yb doctor`** | Find out what is wrong |
| `yb plugin [Name] [#channel …]` | Show or change the plugin |
| `yb channels [#channel …]` | Change the channels |
| `yb slack [you]` | Change who receives the replies |
| `yb device [name]` | Show or set this computer's name |
| `yb autostart [on\|off]` | Start again by itself when you log in to the Mac |
| `yb check` | Check the token and the Slack scopes |
| `yb run` | Run once now (the main session does this every 10 minutes) |
| `yb collect` | Pick up finished ticket sessions now |
| `yb rescan [days]` | Read the channels again after changing the plugin, channels or keywords |
| `yb report` | Print a report now |
| `yb close T7\|all` | Close ticket sessions |
| `yb cleanup [-y]` | Close finished sessions and remove their worktrees |
| `yb attach` | View the main session (Ctrl+B, D to leave) |
| `yb ping` | Test the phone notification |
| `yb log` | Follow the log |
| `yb cloud [url\|off]` | Show, turn on or turn off sharing between computers |
| `yb takeover` | This computer takes the work over now |
| `yb boot` | What autostart runs; you can also run it by hand |
| `yb reset` | Delete the queue and ticket history, keep the config |
| `yb manifest` · `yb install` | Print the Slack app manifest · install the `yb` command |

## Troubleshooting

Run `yb doctor` first.

| Problem | Fix |
|---|---|
| `invalid_auth` | Wrong token: run `yb setup xoxb-…` again |
| `missing_scope`, or no channels listed | `yb check` shows the missing scopes; add them under *Bot Token Scopes*, **Reinstall to Workspace**, then run `yb setup` again |
| A channel is missing | It is private: `/invite @YayBot`, then `yb channels` |
| No ticket processed | No new tickets yet: `yb try` or `yb scan 30` |
| A ticket was missed | Add the channel with `yb channels` or use `:all`, then `yb rescan 7` |
| No reply in the thread | You must be a member of the channel; run `yb collect` |
| No notification | `yb ping`; open the Claude app; allow notifications; turn off Do Not Disturb |
| No session on the phone | Use the same claude.ai account; `claude update`; `yb attach` to see errors |
| A ticket session stays "working" | `tmux attach -t yb-T7` to look at it |
| `Cannot reach …` (cloud) | `git ls-remote <url>`; use the HTTPS URL or log in to the right GitHub account |

Advanced settings and other problems: see [README.md](README.md).
