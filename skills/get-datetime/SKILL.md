---
name: get-datetime
description: Get current date and time - Returns the current date and time in various formats (iso, human, unix)
---

# Get DateTime Skill

## When to use
When user asks for current time, date, or datetime, use this skill to provide the information.

## How to get datetime
Use the bash tool to run `date` command with appropriate format:

- ISO format: `date "+%Y-%m-%d %H:%M:%S"`
- Unix timestamp: `date +%s`
- Human readable: `date`