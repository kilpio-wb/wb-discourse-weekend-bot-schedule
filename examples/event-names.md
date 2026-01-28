# Event naming cheat sheet

Only events whose names start with `BOT `, `SCHEDULE `, or `BASE ` are used.

## Baseline schedule (recurring)

```
SCHEDULE ON — weekends
SCHEDULE OFF — weekdays
```

## Temporary overrides (active window only)

```
BOT ON — holiday
BOT OFF — maintenance
```

If they overlap, `BOT OFF` wins.

## Emergency latch (duration ignored)

```
BOT DISABLE — emergency
BOT ENABLE — resume
```

