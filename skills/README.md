# skills/

Custom agent skills, version-controlled here and synced into the swarm so **every
agent** acquires them on boot. Source of truth is this directory; `swarm-sync`
(the `swarm-config-init` service on `make up`, or `make skills-sync`) upserts each
skill into the swarm skill registry. Sync is **upsert-only** — it never deletes
skills you set up in the UI or that ship out of the box; it only aborts on a
**name conflict** (a repo skill whose name already exists but wasn't created here).

## Authoring a skill

One directory per skill; the directory name is the skill name:

```
skills/<skill-name>/
  SKILL.md        # required — Agent Skill format with YAML front-matter
  scripts/ …      # optional — any extra files/scripts (makes it a "complex" skill)
```

`SKILL.md` front-matter must include at least `name` and `description`:

```markdown
---
name: my-skill
description: One line telling the agent when to use this skill.
---

Body: instructions, commands, guardrails…
```

- **Simple skill** = `SKILL.md` only → stored as the skill body.
- **Complex skill** = `SKILL.md` **plus** any other files → the whole directory is
  uploaded and the swarm writes every file onto each worker at
  `~/.claude/skills/<name>/` (and the codex/pi skill dirs). Bundle scripts here so
  agents *run* them instead of re-deriving the logic each task (saves tokens).

## Rules

- **No secrets.** These files are committed. Reference credentials that live in
  `.env` / mounts / swarm config by name; never paste a key.
- **Match the directory name** in front-matter `name` (a mismatch warns).
- Package prerequisites a skill needs (a CLI, a runtime) go in
  [`../packages/global-setup.sh`](../packages/global-setup.sh), not here.

## Apply changes

```bash
make skills-sync        # push skills to the swarm
make restart-agents     # agents pick them up on next boot (or wait for the next boot)
```
