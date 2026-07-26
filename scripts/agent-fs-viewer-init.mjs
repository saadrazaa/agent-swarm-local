// agent-fs-viewer-init — make this deployment browsable by a human.
//
// agent-fs is multi-tenant: every service auto-registers its own identity and
// its key is generated server-side and kept encrypted inside the API. That
// leaves no key you can use to browse the data in https://live.agent-fs.dev.
//
// This reconciler fixes that WITHOUT touching any swarm identity: it ensures a
// dedicated human "viewer" user exists whose API key is AGENT_FS_VIEWER_KEY
// (chosen by you, stored in .env like every other secret), and adds that user
// as a member of every org + drive so one key browses everything.
//
// Direct DB writes are used deliberately: agent-fs offers no invite API that
// works without an org-admin key, and none of the swarm's admin keys are
// knowable (they're server-generated + encrypted). Access is expressed purely
// as org_members / drive_members rows, so we write those.
//
// Idempotent — safe to run on every `up`. If an agent-fs upgrade changes the
// identity schema, only this script needs updating; the swarm is unaffected.
import { Database } from "bun:sqlite";
import { createHash, randomUUID } from "crypto";

const DB_PATH = process.env.AGENT_FS_DB ?? "/data/agent-fs.db";
const email = process.env.AGENT_FS_VIEWER_EMAIL ?? "viewer@local";
const key = process.env.AGENT_FS_VIEWER_KEY ?? "";
const ROLE = "admin"; // full browse of your own single-user stack; no UI edge cases

if (!key) {
  console.log("agent-fs-viewer-init: AGENT_FS_VIEWER_KEY unset — nothing to do.");
  process.exit(0);
}
if (!/^af_[0-9a-f]{64}$/.test(key)) {
  console.error("agent-fs-viewer-init: AGENT_FS_VIEWER_KEY must look like af_<64 hex>.");
  process.exit(1);
}

// agent-fs stores sha256(key) hex in users.api_key_hash — verified against a
// live-registered key, so we can seed a chosen key by writing its hash.
const hash = createHash("sha256").update(key).digest("hex");

const db = new Database(DB_PATH);
db.exec("PRAGMA busy_timeout=10000");

let user = db.query("SELECT id FROM users WHERE email = ?").get(email);
if (!user) {
  const id = randomUUID();
  db.query("INSERT INTO users (id, email, api_key_hash, created_at) VALUES (?, ?, ?, ?)")
    .run(id, email, hash, Math.floor(Date.now() / 1000));
  user = { id };
  console.log(`agent-fs-viewer-init: created viewer '${email}'.`);
} else {
  db.query("UPDATE users SET api_key_hash = ? WHERE id = ?").run(hash, user.id);
  console.log(`agent-fs-viewer-init: viewer '${email}' present — key synced to .env.`);
}

const orgs = db.query("SELECT id FROM orgs").all();
const drives = db.query("SELECT id FROM drives").all();
db.transaction(() => {
  for (const o of orgs)
    db.query("INSERT OR IGNORE INTO org_members (org_id, user_id, role) VALUES (?, ?, ?)").run(o.id, user.id, ROLE);
  for (const d of drives)
    db.query("INSERT OR IGNORE INTO drive_members (drive_id, user_id, role) VALUES (?, ?, ?)").run(d.id, user.id, ROLE);
})();

const orgN = db.query("SELECT count(*) c FROM org_members WHERE user_id = ?").get(user.id).c;
const driveN = db.query("SELECT count(*) c FROM drive_members WHERE user_id = ?").get(user.id).c;
console.log(`agent-fs-viewer-init: viewer can browse ${orgN} org(s) / ${driveN} drive(s).`);
