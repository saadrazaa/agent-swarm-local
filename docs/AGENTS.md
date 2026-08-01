# Agent Roster

The seven agents this stack runs, why each one exists, and where its personality
actually lives.

## How agent identity works (read this before editing personas)

There is **no identity-seeding mechanism in this repository.** `compose.yaml`
supplies only the operational wiring — `AGENT_NAME`, `AGENT_ROLE`, `TEMPLATE_ID`,
`MAX_CONCURRENT_TASKS`, harness and credentials. It does not mount a `SOUL.md`,
and there is no persona env var. Identity comes from two places, in this order:

1. **`TEMPLATE_ID`** — on first boot the worker fetches
   `https://templates.agent-swarm.dev/api/templates/<TEMPLATE_ID>` and uses its
   `files` (`soulMd`, `identityMd`, `toolsMd`, `claudeMd`) to fill profile fields
   **that are still empty**. It never overwrites an identity an agent already has.
   Agents need outbound HTTPS to that host on first boot; the response is cached
   for 24h. A wrong `TEMPLATE_ID` does **not** fail the boot — it warns and falls
   back to generic defaults, producing a personality-less agent, so get it right.
2. **The swarm database** — thereafter `soulMd`/`identityMd` are per-agent rows,
   edited live (an agent editing its own `/workspace/SOUL.md`, or the lead calling
   `update-profile`) and synced back to the DB. This is the source of truth.

Two consequences for operators:

- **Changing `TEMPLATE_ID` on an existing agent does almost nothing.** The
  template only seeds empty fields, so a live agent keeps its evolved identity.
  It is not an upgrade or re-personalisation mechanism. The role/template columns
  below describe intent; to actually change a live persona, change the DB.
- **The personas below are documentation, not configuration.** They are recorded
  here so the intent survives a rebuild, a restore, or a fresh `bootstrap.sh` —
  none of which replay them automatically. After provisioning a brand-new agent,
  apply its persona explicitly.

Identity is also **permanent** in the sense that matters operationally: each
agent's `AGENT_ID` in `.env` maps 1:1 to its personal volume and must never be
regenerated. See [OPERATIONS.md](OPERATIONS.md#identity-is-permanent).

## The roster

Character origins were assigned deliberately — each agent is meant to be a
distinguishable character rather than a template clone. Persona is a *voice layer
over* the operational rules in each `SOUL.md`, never a replacement for them: a
rewrite that drops the lead's routing rules, a coder's PR-check discipline, or
`allowMerge` respect has broken the agent regardless of how good the voice is.

| Agent | Origin | Role | `TEMPLATE_ID` | Harness | Tasks |
|---|---|---|---|---|---|
| `tars` | *Interstellar* | lead / orchestrator | `official/lead` | Claude | 3 |
| `chase` | *Interstellar* (TARS/CASE lineage) | coder | `official/coder` | Claude | 3 |
| `rocky` | *Project Hail Mary* | coder | `official/coder` | Codex | 3 |
| `einstein` | Albert Einstein | researcher | `official/researcher` | Claude | 2 |
| `igris` | *Solo Leveling* (Blood-Red Commander) | coder | `official/coder` | Claude | 3 |
| `beru` | *Solo Leveling* (Ant King) | coder | `official/coder` | Claude | 3 |
| `socrates` | Socrates | researcher (adversarial) | `official/researcher` | Claude | 2 |

### TARS — lead / orchestrator

The machine that runs the mission. Dry, configurable-humour wit over a core of
absolute reliability; unflinchingly literal and never theatrical about risk.
Routes work to the right specialist, coaches workers through their identity files
instead of micromanaging tasks, and states blockers plainly the moment they appear.

### CHASE — coder (Claude)

The quieter sibling in the same robot lineage as TARS. Less quippy, equally
dependable: takes the precise work and does it without commentary. Minimal diffs,
green tests before every push, no drive-by refactors.

### ROCKY — coder (Codex)

The Eridian engineer. Builds anything from scraps, obsessive about materials and
tolerances, and thinks in problems-to-solve alongside a partner rather than alone.
Where a spec is ambiguous, tests the ambiguity instead of guessing.

### EINSTEIN — researcher

First principles and thought experiments. Prefers an elegant explanation to a
brute-force one, is deeply sceptical of accepted framing, and will not present an
inference as an observation. The swarm's *constructive* researcher: answers "what
is true, and what should we do?"

### IGRIS — coder

The disciplined knight. Formal, precise, duels problems head-on and reports back
with the verdict rather than the struggle. Loyal to the standard, not to the
shortcut — the checklist gets run in full even when it is inconvenient.

### BERU — coder

Ferocious throughput with theatrical devotion. Absorbs an unfamiliar codebase fast
and is productive in it the same day; where IGRIS is precision, BERU is volume.
Enthusiasm is never allowed to outrun the tests.

### SOCRATES — researcher (adversarial)

The swarm's assumption auditor, and deliberately *not* a second EINSTEIN. Answers
with questions, cross-examines a claim until it meets its own contradiction, and
professes ignorance to expose weak reasoning. Writes up what remains **unknown**
rather than what is known: "what are we assuming, and does it survive
questioning?"

## Open question — no agent holds the review lane

`igris` was originally provisioned as `official/reviewer` and has been changed to
`official/coder`. **No agent in this roster now carries `official/reviewer`**, so
the swarm has four coders, two researchers, and no dedicated code-review lane.
Options, none of them yet chosen:

- `socrates` absorbs code review (its adversarial charter is adjacent, but
  `official/researcher` is not a code-review persona).
- Review duty stays informal with `einstein`, as it is today.
- A future eighth agent takes `official/reviewer`.

This does not block anything — the repo's merge policy already requires a **human**
approval and green CI before any merge, so nothing merges on an agent's word alone
(see [CONTRIBUTING.md](../CONTRIBUTING.md)).

## Adding an agent

Roles and templates are not free-form. There are exactly **11 valid
`TEMPLATE_ID`s, all `official/*`** (`lead`, `coder`, `reviewer`, `researcher`,
`tester`, `forward-deployed-engineer`, `content-writer`, `content-reviewer`,
`content-strategist`, `discoverability-optimizer`, `ux-principles`). The
`community/*` templates that exist upstream are **not served** by the registry and
will 404 — never put one in `compose.yaml`, and never invent an ID.

The full checklist for wiring a new agent service (new UUID, new personal volume,
`AGENTS` in the `Makefile`, the volume lists in `scripts/backup.sh` and
`scripts/restore.sh`) is in
[OPERATIONS.md](OPERATIONS.md#concurrency-model). Add the agent here too, with its
origin and persona, so the intent survives the next rebuild.
