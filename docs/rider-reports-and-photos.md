# Rider reports, photos, and the backend they need

Status: **plan, nothing built.** Written 2026-08-05. Supersedes nothing.

This is the first thing JustGo has proposed that cannot be done on the device alone. Everything
until now — routing, packs, the operator fetch — is either bundled or read directly by the rider's
phone and cached for nobody else. Structured reports and shared photos are different in kind: they
are *other people's* data arriving on *this* rider's screen, and that needs a server, a moderation
rule, and a licence.

The order below is deliberate. Each stage is useful shipped alone, and each one that involves other
people's data comes after the one that proves the shape without them.

---

## What already exists

More than I expected. The client half of photos is largely modelled:

| Piece | Where | State |
|---|---|---|
| Photo identity | `PersonalStationMediaKey` (cityID + canonical station ID, validated, length-capped) | done |
| "What does this answer" | `PersonalStationMediaSubject`: `transferCorridor`, `exitSign`, `platform`, `stationMap` | done |
| Share lifecycle | `PersonalStationMediaShareState`: `local` → `queued` → `submitted` → `published` / `rejected` | schema done, only `.local` ever written |
| Capture + storage | `PersonalStationMediaSection.swift`, image picker, on-device index | done |
| Trust labels | `DataConfidence.communityVerified` and `.personal`, with labels and colours | done, unused |
| Trip history | `TripMemoryService.tripRecords`, `recordPlannedTrip`, `markTripComplete` | done, wired |

The share states were written forward-compatibly on purpose — the file's own comment says turning
upload on should be a migration of *state*, not of schema. That holds up.

What does **not** exist: any server, any upload, any moderation, any aggregation. All four
`CityPack*URL` Info.plist keys are empty, so there is not even a static host today.

---

## Stage 1 — post-trip questions, answered for yourself only

No backend. No upload. The rider finishes a trip and is asked at most **two** questions, chosen by
what the app could not answer for that specific trip.

The trigger already exists: `markTripComplete` fires at the end of a recorded trip. The questions
are drawn from the trip's own unknowns, so they are never generic:

- The route claimed step-free access it could not verify → *"Was there a lift from the concourse to
  the platform at 雍和宫?"* (`yes` / `no` / `didn't look`)
- The trip changed lines somewhere with no published transfer info → *"How long did the change at
  西直门 take?"* (`under 5 min` / `5–10` / `over 10`)
- The destination exit was chosen by straight-line distance → *"Did Exit C come out on the right
  side?"* (`yes` / `no, I'd use another`)

Stored on the device, keyed by `PersonalStationMediaKey`'s identity scheme. Two things use them
immediately, both entirely local:

1. **The rider's own future trips.** A transfer they reported as slow is costed higher for them.
   `DataConfidence.personal` already exists to label it.
2. **Nothing else.** No aggregation, no sharing, no account.

This is worth shipping alone. It is also the only honest way to find out whether riders answer at
all — if they don't, Stages 3–5 are moot and cost nothing.

**Rule that must survive into every later stage:** a question is only asked when the app genuinely
does not know. Asking about something already in an official feed trains riders that their answers
don't matter.

---

## Stage 2 — photos, still local, with the subject question

Already 70% built. What's missing is that the four subjects exist but the capture flow doesn't
insist on one, and a photo whose subject is unknown is the "unlabelled corridor snapshot" the model
comment warns about.

Ship: subject required at capture, photos surfaced on the station page, `.personal` confidence
label, and an explicit "on this device only" statement. Still no server.

---

## Stage 3 — the backend: what it must be before it exists

This is the decision point, and it should be made deliberately rather than discovered.

### Constraints that are not negotiable

- **Cost.** The reason there is no Amap API is 50K/year. A backend must be cheap enough to be
  boring: object storage plus a small API, not a managed platform with per-request pricing that
  scales with success.
- **The honesty rule applies to community data too.** A rider report is not official. It must
  render as `communityVerified` at best, never as `official`, and the freshness date must be
  visible. `validate_indoor_maps.rb` forbids packs carrying `transferPaths` because nobody verified
  them — a crowd of three riders does not make a verified transfer path either. **Community reports
  may qualify a claim; they may not create one.**
- **Accessibility claims need a higher bar than everything else.** A wrong "lift available" strands
  someone. Proposed rule: a step-free claim is shown only with **three independent reports agreeing
  and none disagreeing within 90 days**, and it never overrides an operator's own statement — it
  fills silence, it does not contradict.
- **Photos are copyrighted by the person who took them.** Sharing requires an explicit licence
  grant at upload time, per photo, in plain language. This is the same discipline the data-rights
  validators enforce for sources — it should not get looser because the contributor is a user.
- **Photography inside stations is not always permitted in mainland China.** Operators post
  restrictions; enforcement is inconsistent. The app must not instruct riders to photograph
  anything, and the capture prompt should say to follow posted signage. This is a real legal
  exposure, not a formality.

### Shape

The cheapest thing that satisfies the above:

- **Ingest:** a small authenticated-by-device-token API. No accounts — a rotating anonymous device
  identifier is enough to rate-limit and to let a contributor delete their own submissions. The "no
  accounts, ads or social" rule stands.
- **Moderation:** a queue, human-reviewed, with photos defaulting to rejected on timeout rather
  than published. Faces and licence plates blurred or rejected.
- **Egress:** the aggregated result is published as **static JSON on the same contract the app
  already consumes** — `StationInfoAPI/` has `directory.json`, `sources.json`, a schema and an
  `API.md`. A community layer should be another source in that registry with
  `access.kind: communityAggregate`, so the app reads it through machinery that already exists and
  adding it is a data change rather than a routing change.

That last point is the important one. It means the device never talks to a live database — it
downloads a file, exactly as it does for city packs. Offline-capable stays true, and the failure
mode of the backend being down is stale data, not a broken app.

### What it is not

Not a feed, not comments, not profiles, not karma, not free text. Every submission is one of a
fixed set of structured answers, or a photo with a declared subject. Free text is a moderation
liability with no product benefit here.

---

## Stage 4 — reports become shared data

Only after Stage 3 exists and Stage 1 has shown riders answer. Aggregate the structured answers,
publish through the community source, render as `communityVerified` with a freshness date and a
report count. Never as `official`.

## Stage 5 — photos become shared data

Last, because it is the highest moderation cost and the highest legal exposure for the least
routing value. A photo helps a stranger standing where the contributor stood; it does not change a
route. `submitted` and `published` finally get written, which is the migration the schema was built
for.

---

## Open questions for the next discussion

1. **Who moderates?** Human review does not scale to one person. Either the volume stays tiny by
   design (one city, high-traffic interchanges only) or this needs a plan before Stage 4, not after.
2. **Where does it run?** Mainland reachability matters — a host that is slow or blocked from within
   China makes the community layer useless for the primary audience. This constrains the choice more
   than price does.
3. **Does the 3-report threshold for accessibility hold at low volume?** In a city with 40 active
   contributors it may mean no step-free claim ever clears the bar. If so the honest answer is to
   keep accessibility reports device-local (Stage 1) indefinitely and share only transfer timings
   and exit choices.
4. **Saved trips.** Deleted in `11b6d2d` because it had no write path. The "familiar route" idea it
   was reaching for is good and belongs with Stage 1's memory work — rebuild it there, with a create
   path, rather than restoring the corpse.
