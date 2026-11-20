![An agent drives a macOS app in the background while the person keeps working](preview.svg)

## What this gives the agent

The agent can bind to any running macOS app and drive it — clicking, typing,
reading the screen, recording it — while the app is in the background, behind
other windows, minimised, on another Space, or hidden. The person's pointer,
focus, and window order are never touched.

## What it needs from the person

Three macOS permissions, granted once, in **System Settings → Privacy &
Security**:

| Permission | Why |
|---|---|
| Accessibility | read the app's controls and press them |
| Post events | deliver keystrokes and clicks to the app's process |
| Screen recording | capture what the app looks like |

## Where things land

Each agent gets its own directory, `/tmp/quiet-driver/agent-<id>/`, for
screenshots and recordings. An agent can also save to any path it names.

## When it gets in the way

The agent can report the problem with `log_friction`, and read the collected
backlog with `friction_log`. Every entry is kept, so rough edges get fixed
instead of being rediscovered.
