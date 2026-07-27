// swarm-sync — reconcile repo-declared skills + packages into the swarm.
//
// Mirrors scripts/agent-fs-viewer-init.mjs: a small, idempotent bun script that
// is safe to run on every `up` and that nothing depends on (a failure never
// blocks the swarm). It is run by the `swarm-config-init` compose service and
// by `make swarm-sync` / `make skills-sync` / `make packages-sync`.
//
// What it does (see docs/superpowers/specs/2026-07-27-swarm-skill-and-package-sync-design.md):
//   • skills   — each skills/<name>/ dir is upserted into the swarm skill
//                registry as an all-agents skill. SKILL.md-only dirs are simple
//                (content); dirs with extra files are complex (files[] upload,
//                delivered to every worker filesystem by the swarm itself).
//   • packages — packages/global-setup.sh is pushed to the swarm's global setup
//                script config; every worker runs it as root on boot.
//
// Source of truth is the repo; sync is UPSERT-ONLY and never prunes. A repo
// skill whose name already exists in the swarm but was NOT created by this repo
// (a UI / out-of-the-box skill) is a hard naming conflict and aborts the run.
//
// Env:
//   SYNC            all | skills | packages           (default: all)
//   SWARM_API_URL   API base URL                       (default: http://api:3013)
//   API_KEY         operator key (required to apply; absent ⇒ dry-run)
//   SKILLS_DIR      skills directory                   (default: /skills)
//   PACKAGES_DIR    packages directory                 (default: /packages)
//   DRY_RUN=1       print intended requests, touch no network
//
// NOTE (contract): the swarm REST field names below are taken from the pinned
// image's DB schema (migrations 019_skills / 080_skill_system_defaults /
// 087_skill_files) and observed request fragments. They are centralized in the
// `Swarm` client so the first live run can confirm/adjust them in one place.

import { readdirSync, readFileSync, statSync, existsSync } from "node:fs";
import { join, relative, sep } from "node:path";

const SYNC = (process.env.SYNC ?? "all").toLowerCase();
const API_URL = (process.env.SWARM_API_URL ?? "http://api:3013").replace(/\/$/, "");
const API_KEY = process.env.API_KEY ?? "";
const SKILLS_DIR = process.env.SKILLS_DIR ?? "/skills";
const PACKAGES_DIR = process.env.PACKAGES_DIR ?? "/packages";
const DRY_RUN = process.env.DRY_RUN === "1" || !API_KEY;

// Marker persisted in the swarm config store so re-syncs can tell repo-owned
// skills (safe to update) from same-named foreign skills (a conflict). Chosen
// over a skills-table column so no schema assumptions are made.
const MANAGED_KEY = "repo_managed_skills";
const GLOBAL_SETUP_KEY = "globalSetupScript";

// ── tiny helpers ────────────────────────────────────────────────────────────

const log = (m) => console.log(`swarm-sync: ${m}`);
const fail = (m) => {
  console.error(`swarm-sync: ERROR — ${m}`);
  process.exit(1);
};

function listSkillDirs(root) {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .filter((name) => existsSync(join(root, name, "SKILL.md")))
    .sort();
}

// All files under a skill dir, as posix-relative paths (SKILL.md first).
function walkFiles(dir) {
  const out = [];
  const rec = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) rec(p);
      else if (e.isFile()) out.push(relative(dir, p).split(sep).join("/"));
    }
  };
  rec(dir);
  return out.sort((a, b) => (a === "SKILL.md" ? -1 : b === "SKILL.md" ? 1 : a.localeCompare(b)));
}

// Minimal front-matter reader: pulls `name:` and `description:` from the leading
// --- ... --- block. Skill front-matter is flat, so a full YAML parser (and its
// dependency) is unnecessary.
function frontmatter(md) {
  const m = md.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  const fm = {};
  if (m) {
    for (const line of m[1].split(/\r?\n/)) {
      const kv = line.match(/^([A-Za-z][\w-]*):\s*(.*)$/);
      if (kv) fm[kv[1].trim()] = kv[2].trim().replace(/^["']|["']$/g, "");
    }
  }
  return fm;
}

function encodeFile(abs) {
  const buf = readFileSync(abs);
  // Binary iff it has a NUL byte or is not valid UTF-8 round-trip.
  const isBinary =
    buf.includes(0) || Buffer.from(buf.toString("utf8"), "utf8").compare(buf) !== 0;
  return isBinary
    ? { content: buf.toString("base64"), isBinary: true, encoding: "base64", size: buf.length }
    : { content: buf.toString("utf8"), isBinary: false, encoding: "utf8", size: buf.length };
}

const MIME = { md: "text/markdown", sh: "text/x-shellscript", js: "text/javascript", ts: "text/typescript", py: "text/x-python", json: "application/json", txt: "text/plain" };
const mimeOf = (path) => MIME[path.split(".").pop()?.toLowerCase()] ?? "application/octet-stream";

// Build the swarm payload for one skill directory.
function buildSkill(name, dir) {
  const md = readFileSync(join(dir, "SKILL.md"), "utf8");
  const fm = frontmatter(md);
  if (fm.name && fm.name !== name)
    log(`warning: ${name}/SKILL.md front-matter name '${fm.name}' != directory name '${name}' (using '${name}')`);
  if (!fm.description)
    log(`warning: ${name}/SKILL.md has no 'description' front-matter — the swarm requires one`);

  const files = walkFiles(dir);
  const isComplex = files.some((f) => f !== "SKILL.md");
  const base = {
    name,
    description: fm.description ?? "",
    scope: "swarm", // all agents in this swarm
    systemDefault: true, // migration 080: auto-installed for every agent
    isComplex,
  };
  if (!isComplex) return { ...base, content: md };
  return {
    ...base,
    content: md, // SKILL.md also stored as the skill body
    files: files.map((rel) => {
      const enc = encodeFile(join(dir, rel));
      return { path: rel, mimeType: mimeOf(rel), ...enc };
    }),
  };
}

// ── swarm client (centralized wire contract — confirm on first live run) ─────

const Swarm = {
  async req(method, path, body) {
    const url = `${API_URL}${path}`;
    if (DRY_RUN) {
      const preview = body ? summarize(body) : "";
      log(`[dry-run] ${method} ${url} ${preview}`);
      return { dryRun: true };
    }
    const res = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${await res.text().catch(() => "")}`);
    const text = await res.text();
    return text ? JSON.parse(text) : {};
  },
  listSkills() {
    return this.req("GET", "/api/skills").then((r) => (Array.isArray(r) ? r : r.skills ?? []));
  },
  createSkill(payload) {
    return this.req("POST", "/api/skills", payload);
  },
  updateSkill(id, payload) {
    return this.req("PUT", `/api/skills/${id}`, payload);
  },
  getConfig(key) {
    return this.req("GET", `/api/config/resolved?key=${encodeURIComponent(key)}`)
      .then((r) => (r.configs ?? []).find((c) => c.key === key)?.value)
      .catch(() => undefined);
  },
  setConfig(key, value) {
    return this.req("POST", "/api/config", { key, value });
  },
};

// Compact body preview for dry-run (never dumps file contents).
function summarize(body) {
  if (body.files) return `{name:${body.name}, isComplex:${body.isComplex}, files:[${body.files.map((f) => f.path).join(", ")}]}`;
  if (body.key) return `{key:${body.key}, value:${String(body.value).length}B}`;
  return `{name:${body.name}, isComplex:${body.isComplex}, content:${(body.content ?? "").length}B}`;
}

// ── reconcilers ──────────────────────────────────────────────────────────────

async function syncSkills() {
  const dirs = listSkillDirs(SKILLS_DIR);
  if (!dirs.length) return log(`no skills under ${SKILLS_DIR} — nothing to sync`);

  const existing = DRY_RUN ? [] : await Swarm.listSkills();
  const byName = new Map(existing.map((s) => [s.name, s]));
  const managed = new Set(JSON.parse((await Swarm.getConfig(MANAGED_KEY)) || "[]"));

  let created = 0, updated = 0;
  for (const name of dirs) {
    const payload = buildSkill(name, join(SKILLS_DIR, name));
    const hit = byName.get(name);
    if (hit && !managed.has(name))
      fail(`naming conflict: a skill named '${name}' already exists in the swarm but was not created by this repo (set up via the UI or shipped by default). Rename the repo skill or remove the existing one.`);
    if (hit) {
      await Swarm.updateSkill(hit.id, payload);
      updated++;
      log(`updated ${payload.isComplex ? "complex" : "simple"} skill '${name}'`);
    } else {
      await Swarm.createSkill(payload);
      created++;
      log(`created ${payload.isComplex ? "complex" : "simple"} skill '${name}'`);
    }
    managed.add(name);
  }
  await Swarm.setConfig(MANAGED_KEY, JSON.stringify([...managed].sort()));
  log(`skills: ${created} created, ${updated} updated, ${dirs.length} declared (upsert-only, no prune)`);
}

async function syncPackages() {
  const script = join(PACKAGES_DIR, "global-setup.sh");
  if (!existsSync(script)) return log(`no ${script} — nothing to sync`);
  const body = readFileSync(script, "utf8");
  const current = await Swarm.getConfig(GLOBAL_SETUP_KEY);
  if (current === body) return log("packages: global setup script unchanged — no-op");
  await Swarm.setConfig(GLOBAL_SETUP_KEY, body);
  log(`packages: pushed global-setup.sh (${body.length}B) to '${GLOBAL_SETUP_KEY}' — applies on next worker boot`);
}

// ── main ─────────────────────────────────────────────────────────────────────

log(`${DRY_RUN ? "DRY-RUN " : ""}SYNC=${SYNC} → ${API_URL}`);
if (!["all", "skills", "packages"].includes(SYNC)) fail(`invalid SYNC='${SYNC}' (want all|skills|packages)`);
try {
  if (SYNC === "all" || SYNC === "skills") await syncSkills();
  if (SYNC === "all" || SYNC === "packages") await syncPackages();
  log("done");
} catch (e) {
  fail(e.message ?? String(e));
}
