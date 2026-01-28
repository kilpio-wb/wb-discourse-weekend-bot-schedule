# frozen_string_literal: true

def env(key, default = nil)
  v = ENV[key]
  v && !v.strip.empty? ? v : default
end

AUTOMATION_NAME = env("BOT_AUTOMATION_NAME", "Test Weekend Auto-Reply")
TZ_NAME         = env("BOT_TIMEZONE", "Europe/Moscow")
DEFAULT_MODE    = env("BOT_DEFAULT_MODE", "weekends") # weekends | on | off
VERBOSE         = env("BOT_VERBOSE", "1") == "1"

Time.zone = TZ_NAME
now = Time.zone.now

def log(msg)
  puts "[bot-schedule] #{msg}"
end

def up(s) = s.to_s.strip.upcase

# ---------- Name classifiers ----------
# Latch (sticky, duration ignored)
def disable_event?(name)
  n = up(name)
  n.start_with?("BOT DISABLE")
end

def enable_event?(name)
  n = up(name)
  n.start_with?("BOT ENABLE")
end

# Overrides (only while active window)
def override_off?(name)
  n = up(name)
  n.start_with?("BOT OFF")
end

def override_on?(name)
  n = up(name)
  n.start_with?("BOT ON")
end

# Baseline schedule (only while active window)
def schedule_off?(name)
  n = up(name)
  n.start_with?("SCHEDULE OFF") || n.start_with?("BASE OFF")
end

def schedule_on?(name)
  n = up(name)
  n.start_with?("SCHEDULE ON") || n.start_with?("BASE ON")
end

# ---------- Default fallback ----------
default_enabled =
  case DEFAULT_MODE.downcase
  when "on" then true
  when "off" then false
  else
    now.saturday? || now.sunday?
  end

# ---------- Sticky latch state (BOT DISABLE / BOT ENABLE) ----------
# We only care about events that have STARTED (<= now). End time is ignored.
latch_rows = DB.query_hash(<<~SQL, now: now)
  SELECT id, name, original_starts_at
  FROM discourse_post_event_events
  WHERE deleted_at IS NULL
    AND name IS NOT NULL
    AND original_starts_at <= :now
    AND (name ILIKE 'BOT DISABLE%' OR name ILIKE 'BOT ENABLE%')
  ORDER BY original_starts_at DESC
SQL

last_disable = latch_rows.find { |r| disable_event?(r["name"]) }
last_enable  = latch_rows.find { |r| enable_event?(r["name"]) }

disable_at = last_disable && last_disable["original_starts_at"]
enable_at  = last_enable  && last_enable["original_starts_at"]

hard_disabled =
  if disable_at.nil?
    false
  elsif enable_at.nil?
    true
  else
    enable_at <= disable_at
  end

# ---------- Active-window events (overrides + baseline schedule) ----------
# Only events active "right now" are relevant here.
active_rows = DB.query_hash(<<~SQL, now: now)
  SELECT id, name, original_starts_at, original_ends_at
  FROM discourse_post_event_events
  WHERE deleted_at IS NULL
    AND name IS NOT NULL
    AND original_starts_at <= :now
    AND (original_ends_at IS NULL OR original_ends_at >= :now)
  ORDER BY original_starts_at ASC
SQL

# Keep only schedule-related names (optional safety net)
active_rows = active_rows.select do |r|
  n = up(r["name"])
  n.start_with?("BOT ") || n.start_with?("SCHEDULE ") || n.start_with?("BASE ")
end

override_off_active = active_rows.any? { |r| override_off?(r["name"]) }
override_on_active  = active_rows.any? { |r| override_on?(r["name"]) }
sched_off_active    = active_rows.any? { |r| schedule_off?(r["name"]) }
sched_on_active     = active_rows.any? { |r| schedule_on?(r["name"]) }

# ---------- Decision ----------
desired_enabled = nil
reason = nil

if hard_disabled
  desired_enabled = false
  reason = "HARD DISABLED (last DISABLE at #{disable_at}#{enable_at ? ", last ENABLE at #{enable_at}" : ""})"
else
  if override_off_active
    desired_enabled = false
    reason = "override BOT OFF active"
  elsif override_on_active
    desired_enabled = true
    reason = "override BOT ON active"
  elsif sched_off_active
    desired_enabled = false
    reason = "baseline SCHEDULE OFF active"
  elsif sched_on_active
    desired_enabled = true
    reason = "baseline SCHEDULE ON active"
  else
    desired_enabled = default_enabled
    reason = "fallback default (mode=#{DEFAULT_MODE})"
  end
end

# ---------- Toggle automation ----------
automation = DiscourseAutomation::Automation.find_by(name: AUTOMATION_NAME)
raise "Automation not found by name: #{AUTOMATION_NAME.inspect}" unless automation

current_enabled =
  if automation.has_attribute?(:enabled)
    !!automation.enabled
  elsif automation.has_attribute?(:disabled)
    !automation.disabled
  elsif automation.has_attribute?(:is_enabled)
    !!automation.is_enabled
  else
    raise "Don't know how to read enabled state for automation id=#{automation.id}"
  end

if VERBOSE
  log "now=#{now} tz=#{TZ_NAME}"
  log "latch: disable_at=#{disable_at.inspect} enable_at=#{enable_at.inspect} hard_disabled=#{hard_disabled}"
  log "active: override_off=#{override_off_active} override_on=#{override_on_active} sched_off=#{sched_off_active} sched_on=#{sched_on_active}"
  log "automation='#{AUTOMATION_NAME}' current=#{current_enabled} desired=#{desired_enabled} reason=#{reason}"
end

if current_enabled == desired_enabled
  log "no change"
else
  if automation.has_attribute?(:enabled)
    automation.update!(enabled: desired_enabled)
  elsif automation.has_attribute?(:disabled)
    automation.update!(disabled: !desired_enabled)
  else
    automation.update!(is_enabled: desired_enabled)
  end
  log "changed: enabled=#{desired_enabled}"
end
