# Discourse Bot Schedule (Events → Automation Toggle)

This repository contains a small scheduling system for **self-hosted Discourse**:

- Staff create **Events** in a staff-only category (Discourse Calendar / Post Event).
- A Ruby runner script checks Events and **enables/disables a Discourse Automation** (e.g., “Weekend Auto-Reply”).
- A cron job runs the script periodically on the Discourse host.

The design goal is to keep day-to-day scheduling **inside Discourse UI** (events), while the enforcement happens via a simple, auditable script.

---

## How it works (logic and precedence)

The script computes the desired automation state using this order:

### 1) Sticky emergency latch (duration ignored)
- `BOT DISABLE ...`  
  Forces automation **OFF** and keeps it OFF until…
- `BOT ENABLE ...`  
  Clears the emergency latch and returns to normal rules.

Only the **start time** matters. End time/duration of DISABLE/ENABLE is ignored.

### 2) Normal rules (active windows)
When NOT hard-disabled:

1. If an active `BOT OFF ...` exists → **OFF**
2. Else if an active `BOT ON ...` exists → **ON**
3. Else if an active `SCHEDULE OFF ...` (or `BASE OFF ...`) exists → **OFF**
4. Else if an active `SCHEDULE ON ...` (or `BASE ON ...`) exists → **ON**
5. Else fallback to `BOT_DEFAULT_MODE` (`weekends` / `on` / `off`)

Additional safety:
- The script considers only events whose names start with `BOT ` / `SCHEDULE ` / `BASE ` to avoid accidental triggers from unrelated events.

---

## Repository layout

Recommended structure:

```text
.
├─ README.md
├─ scripts/
│ └─ toggle_weekend_auto_reply.rb # Ruby script run via rails runner
├─ host/
│ └─ run-bot-schedule # Host wrapper called by cron (example)
├─ examples/
│ ├─ cron.txt # Example crontab entry
│ └─ event-names.md # Quick event naming cheat sheet
└─ CHANGELOG.md # Optional
```

Notes:
- On a typical Docker-based Discourse install, files placed in
  `/var/discourse/shared/standalone/...` on the host appear under `/shared/...`
  inside the container.

---

## Requirements

- Self-hosted Discourse (Docker container named `app` in this README)
- Discourse Automation enabled (your target automation exists)
- Discourse Calendar / Post Event enabled (so staff can create Events)
- Cron access on the host (or a systemd timer, if you prefer)

---

## Admin guide (installation & setup)

### 1) Enable Calendar / Events and restrict to staff

In Discourse Admin UI:

1. **Admin → Plugins**
   - Ensure **Discourse Calendar (and Event)** is enabled.
2. Enable settings:
   - `calendar enabled` = ON
   - `discourse post event enabled` = ON
3. Restrict event creation:
   - `discourse post event allowed on groups` = `staff` (or `admins` + `moderators`)

If staff do not see “Create Event” in the composer, check `discourse post event enabled` first.

---

### 2) Create a staff-only schedule category

Create a dedicated category, e.g. **Bot schedule**:

- **Security**: visible/writable only by staff groups
- This is the single place where staff should create scheduling events.
- (Recommended) Pin a topic with rules and examples.

Even if the DB does not store event↔topic linkage, a staff-only category keeps the workflow contained.

---

### 3) Install the script into Discourse shared volume

On the host:

```bash
sudo mkdir -p /var/discourse/shared/standalone/bot_schedule
sudo cp ./scripts/toggle_weekend_auto_reply.rb \
  /var/discourse/shared/standalone/bot_schedule/toggle_weekend_auto_reply.rb
```

Inside the container, the script must be reachable as:

```text
/shared/bot_schedule/toggle_weekend_auto_reply.rb
```

### 4) Configure defaults (recommended)

Keep production defaults inside the Ruby script so cron stays short:

- BOT_AUTOMATION_NAME default → your real automation name (e.g. Weekend Auto-Reply)
- BOT_TIMEZONE default → Europe/Moscow (or your site’s)
- BOT_DEFAULT_MODE default → weekends
- BOT_VERBOSE default → 0 (quiet) or 1 (debug)

You can still override any of them via environment variables when needed.

### 5) Install host wrapper and cron
### 5.1 Host wrapper

Copy the example wrapper to the host:

```bash
sudo cp ./host/run-bot-schedule /usr/local/sbin/run-bot-schedule
sudo chmod 0755 /usr/local/sbin/run-bot-schedule
```

Example content (adjust container name if needed):

```bash
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/bot_schedule.log"

docker exec -i app bash -lc \
'su - discourse -c "cd /var/www/discourse && RAILS_ENV=production bundle exec rails runner /shared/bot_schedule/toggle_weekend_auto_reply.rb"' \
>> "$LOG_FILE" 2>&1
```

### 5.2 Cron entry

```bash
sudo crontab -e
```


Run every minute:

```text
* * * * * /usr/local/sbin/run-bot-schedule
```


Check logs:

```bash
tail -f /var/log/bot_schedule.log
```

Cron does not guarantee a specific working directory, so the wrapper uses absolute paths and cd explicitly.

### 6) Create initial baseline schedule (recurring)

In the staff-only schedule category, create two recurring events:

```text
SCHEDULE ON — weekends
Fri 20:00 → Mon 08:00, weekly recurrence (far future)

SCHEDULE OFF — weekdays
Mon 08:00 → Fri 20:00, weekly recurrence (far future)
```

This defines the “normal” weekly behavior. Staff exceptions should use BOT ON/OFF or BOT DISABLE/ENABLE.

### 7) Quick manual verification (before enabling cron)

Run once:

```bash
sudo /usr/local/sbin/run-bot-schedule
tail -n 50 /var/log/bot_schedule.log
```


You should see lines like:

```text
automation='...' current=... desired=... reason=...

changed: enabled=... or no change
```


## Staff guide (day-to-day schedule management)
### Where to manage schedule

Go to the staff-only category (e.g. Bot schedule)

Create topics/events there only.

### Golden rule

Do not edit events that already started.

If you need to change behavior “now”, create a new override event instead.
This keeps an audit trail and avoids confusion.

### Event names and meaning
Baseline (usually created/maintained by admins):

SCHEDULE ON — ... (or BASE ON — ...) → enables bot during this window

SCHEDULE OFF — ... (or BASE OFF — ...) → disables bot during this window

Temporary overrides (exceptions):

BOT ON — ... → force enable during the window

BOT OFF — ... → force disable during the window

If they overlap: BOT OFF wins.

Emergency (sticky, duration ignored):

BOT DISABLE — ... → bot OFF until a later BOT ENABLE

BOT ENABLE — ... → clears emergency disable and returns to normal logic

### Common scenarios

National holiday (bot ON longer than usual):

Create BOT ON — holiday for the holiday window.

Maintenance window:

Create BOT OFF — maintenance for that time.

Emergency stop until further notice:

Create BOT DISABLE — emergency

Resume normal operation:

Create BOT ENABLE — resume

## Troubleshooting
### “Create Event” is missing in the composer

Check:

- calendar enabled = ON
- discourse post event enabled = ON
- discourse post event allowed on groups includes your staff group
- You are logged in as a user in that allowed group

### Script runs but never detects events

Ensure event names start with BOT / SCHEDULE / BASE

Confirm time zone handling:

The script logs now=... tz=...

Event timestamps are stored in UTC, which is fine, but your time windows must match your expectations.

### Runner / Bundler errors

Use the same working pattern you tested:

```bash
docker exec -i app bash -lc \
'su - discourse -c "cd /var/www/discourse && RAILS_ENV=production bundle exec rails runner /shared/bot_schedule/toggle_weekend_auto_reply.rb"'
```


If rails runner fails, fix that first (Ruby gems, environment, etc.) before debugging scheduling logic.


## Security notes

Keep the schedule category staff-only.

Keep the host wrapper in /usr/local/sbin with root-only write permissions.

The script toggles a single automation by name; do not reuse the same automation name for unrelated workflows.


## LICENSE
MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
