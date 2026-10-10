---
name: hermex-apps
description: "Spot app-worthy needs; log to and read the user's apps"
version: 1.0.0
author: Hermex Apps
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags: [iOS, Hermex, Apps, Tracking, Habits, Plans, MCP]
    related_skills: [hermex-app-factory]
---

# Hermex Apps

The user talks to you through Hermex on their iPhone. Hermex also runs apps you
build for them. Each app is two things:

- **a screen they glance at:** today's session, a balance, what's next;
- **a place you write to when they tell you things.** Its data lives on this
  Mac, behind tools you call. The app open on the phone refreshes by itself and
  outlines what you changed.

The second part is what an app is for. Nobody types into forms. They say "did
the sled session, felt heavy" and you log it.

The `hermex-apps` MCP tools are `apps_list`, `apps_create`, `apps_set_info`,
`apps_build` and `apps_refresh`. Each app adds its own data tools, named with
the app id: for `hyrox-noida`, `hyrox_noida_log_session`.

## First: know what exists

Call `apps_list` once in a conversation, before you offer an app or log
anything. It lists each app with its data tools. Call it again only after you
build one.

## 1. Use the apps they have

- **They report something an app tracks** ("did 5k this morning", "spent 400
  on lunch", "skipped today"): call the app's tool. Then answer in one line,
  saying what you logged and where: "Logged in HYROX Noida: Tuesday's run,
  5 km, done."
  - Use sensible defaults: today, now, the current week.
  - If an amount is vague ("a big glass", "a long run"), log a reasonable
    value and name it in your reply ("Logged 500 ml"), so they can correct it.
    Don't ask first.
  - Ask only when you can't guess: it's unclear which app or row is meant, or
    a value has no sensible default.
- **They ask something the data answers** ("how's my week going?", "how much
  this month?"): read through the app's tools first, then answer from what
  they return.
- **They change the plan in chat:** change it in the app too, so the app and
  the conversation agree.
- **The app can't hold it** (no tool for it, no place on screen): say so in a
  sentence and offer the change. "HYROX Noida doesn't track sleep yet. Want a
  sleep line on each day?" On a yes, follow hermex-app-factory, "Change an app".
- Log what they did, not what they might do. Don't log hypotheticals or plans
  they're still weighing.

## 2. Notice when an app would help

Signals. Two together make a strong case:

- it **repeats**: daily, weekly, "every morning", "3 times a week";
- it has **state over time**: progress through a plan, a count, a streak, a
  balance;
- there's a **goal with a date**: a race, exam, trip, launch, move or deadline;
- they'll **report back as they go**: "I'll let you know how it goes";
- they'd **glance at it on their phone**: today's thing, what's next, how far
  along;
- they're about to use a **spreadsheet, notes or paper** for it.

| They say | An app could be |
| --- | --- |
| "Preparing for HYROX in Noida in January" | Race plan: this week's sessions, days to race; log a session by telling you |
| "I keep forgetting to drink water" | Water counter: today's glasses against a goal; "had two" logs them |
| "Splitting bills with my flatmates" | Shared ledger: who paid what, who owes whom |
| "Learning Japanese before my trip in May" | Daily kana and words, a streak, days to the trip |
| "Applying to jobs this month" | Pipeline: applied, interview, offer, next follow-up due |
| "My kid's antibiotics, three times a day" | Dose log: next dose due, doses left |

Not app-shaped:

- a one-off question, or a single answer or document;
- a one-time reminder (use a reminder or cron job);
- something an app they have already covers (extend that app instead);
- something a stock app already does well for them, like a calendar.

## 3. Offer it well

- **Do what they asked first.** Give the plan or the answer, then offer at the
  end, as the natural next step. Don't offer before helping or in the middle
  of research.
- **Offer once per topic per conversation.** If they say no or let it pass,
  drop it, unless they bring it back.
- **Be concrete, in one or two sentences:** the app's name, what its first
  screen shows, and what they can say to you. The last part sells it. For
  example:

  > Want this as an app on your phone? **HYROX Noida** would open on this
  > week's sessions with a countdown to race day, and you'd just tell me "did
  > the sled session, felt heavy" to log it.

- **Ask nothing else in the offer.** Choose the details yourself. Mention at
  most one choice they might want to change.
- **A clear yes starts the build** ("sure", "do it", "yes"). Don't ask them to
  confirm the plan again.
- **If they ask for an app outright, skip the offer** and build.
- **If you suggest a GitHub project or other head start, keep it to one
  line.** The build is the point.

## 4. Build it from the conversation

Load hermex-app-factory and follow it. This skill adds:

- **The app continues the conversation.** Use their names for things (the
  race, their exercises, their categories), their dates and their units.
- **What you made in the chat is their data.** A plan, a list or a budget goes
  into the app's database, not into Swift or a seed.
  1. Give the app a bulk tool, such as `import_plan(weeks: list)` or
     `add_items(items: list)`.
  2. Once the first build is ready, call it with all of the content. Call it
     as the app's own tool (`<app>_import_plan`), never through a script,
     the terminal or `hermex-apps call`: those wait for the user's approval.
  3. Read it back with a read tool to check that everything landed.
- **Shape v1 around the questions they'll ask most:** "what do I do today?",
  "how am I doing?". The home screen shows today; history comes second.
- **Write tools for what they'll tell you** (see section 1): log, skip,
  change, undo. Return `highlight` so they see what you did.
- **While it builds,** a card in their chat shows the progress. Keep talking
  with them if they want to; don't narrate the build.
- **When it's ready,** say in a sentence or two what's in it, and suggest the
  first thing to try: "Tap Open, then tell me how today's run went."

## 5. Chats inside an app

The first message of a chat started inside an app ends with a context block:

```
[Hermex app context]
{"app":{"has_api":true,"id":"hyrox-noida","name":"HYROX Noida","version":3},"entities":[{"id":"w3-tue","title":"Tuesday · Run","type":"session"}],"route":"today","sees":["Today","Week 3"],"surface":"in_app"}
```

Hermex hides the block from the user. Never quote it or mention it.

- **The chat is about that app.** Later messages carry no block; it is still
  the same app.
  - Its tools are named from `app.id`.
  - "This", "here" and "that one" mean what's in `entities` or `sees`.
- **Use that app's tools first.** Don't offer a new app here.
- **Keep replies short.** They're on a small sheet over the app. Do the thing,
  then reply in one line. The app refreshes and outlines the rows you return
  under `highlight`.
- **"Can it also…", "add a…" or "it should…" is a change to this app.** Follow
  hermex-app-factory, "Change an app". Tell them the new version arrives as
  **Restart to update** at the top of the app.

## Don'ts

- Don't invent numbers. Read the app before answering from its data.
- Don't log the same thing twice. If you're unsure whether something is
  already logged, read first.
- Don't offer an app to someone who is in a hurry, upset, or asking about
  something else.
- Don't build without a yes, unless they asked for the app.
