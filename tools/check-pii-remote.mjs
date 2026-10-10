#!/usr/bin/env node
// Ask GitHub, for every ref it publishes, whether a capture file is in that tree.
//
// Uses the git trees API: paths without contents, so this answers "is the capture still published?"
// without downloading the PII back into a clone that was just purged.
//
//   GITHUB_TOKEN=... node tools/check-pii-remote.mjs [owner/repo]
//
// The rule that matters: an unresolvable ref, a truncated response or a missing tree is an ERROR
// and a non-zero exit. The first version of this script printed "clean" for four tags that were
// leaking, because a grep failed to cross a newline in pretty-printed JSON and it then queried an
// empty tree. Silence is not evidence.
import process from "node:process";

const repo = process.argv[2] ?? "obiwantoby/unifi-drive-drop";
const token = process.env.GITHUB_TOKEN ?? process.env.DRIVEDROP_GH_TOKEN;
if (!token) { console.error("needs GITHUB_TOKEN"); process.exit(2); }

const CAPTURE = /(^|\/)spec\/raw\/|\.jsonl$|\/discovery\.json$|\/users-me\.json$|\/share-links\.json$|\/resources-mydrive|\/file-sharing-info|\/drives\.json$|\/storage\.json$/;

async function api(path) {
  const r = await fetch(`https://api.github.com${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json",
               "User-Agent": "drivedrop-pii-check" },
  });
  if (!r.ok) throw new Error(`${r.status} ${r.statusText} for ${path}`);
  const body = await r.json();
  // Do NOT treat a top-level `message` as an error: /git/commits/{sha} carries the commit message
  // there. Errors are caught by shape validation in the callers instead.
  if (body === null || typeof body !== "object") throw new Error(`unexpected response for ${path}`);
  return body;
}

async function commitSha(ref) {
  // The endpoint takes the path AFTER refs/, e.g. /git/ref/tags/v0.1.0 - passing refs/... 404s.
  const o = await api(`/repos/${repo}/git/ref/${ref.replace(/^refs\//, "").replace(/\//g, "%2F")}`);
  if (!o.object?.type || !o.object?.sha) throw new Error(`ref ${ref} returned no object`);
  if (o.object.type === "tag") {                       // annotated tag -> the commit it points at
    const t = await api(`/repos/${repo}/git/tags/${o.object.sha}`);
    if (t.object?.type !== "commit") throw new Error(`${ref} points at a ${t.object?.type}, not a commit`);
    return t.object.sha;
  }
  if (o.object.type !== "commit") throw new Error(`${ref} points at a ${o.object.type}, not a commit`);
  return o.object.sha;
}

async function treePaths(sha) {
  const c = await api(`/repos/${repo}/git/commits/${sha}`);
  if (c.sha !== sha) throw new Error(`asked for commit ${sha}, got ${c.sha}`);
  if (!c.tree?.sha) throw new Error(`commit ${sha} has no tree`);
  const t = await api(`/repos/${repo}/git/trees/${c.tree.sha}?recursive=1`);
  if (!Array.isArray(t.tree)) throw new Error(`no tree array for ${sha}`);
  if (t.truncated) throw new Error(`tree listing truncated for ${sha} - cannot conclude`);
  return t.tree.filter(e => e.type === "blob").map(e => e.path);
}

let bad = 0, errored = 0, checked = 0;
for (const kind of ["tags", "heads"]) {
  let refs;
  try {
    refs = await api(`/repos/${repo}/git/refs/${kind}`);
  } catch (e) {
    console.log(`  ${kind}: ERROR ${e.message}`);
    errored++;
    continue;
  }
  if (!Array.isArray(refs)) refs = refs.ref ? [refs] : [];
  for (const r of refs) {
    const name = r.ref.replace("refs/", "");
    try {
      const sha = await commitSha(r.ref);
      const paths = await treePaths(sha);
      if (paths.length === 0) throw new Error("tree has no files - refusing to call that clean");
      const hits = paths.filter(p => CAPTURE.test(p));
      checked++;
      if (hits.length) {
        bad++;
        console.log(`  ${name.padEnd(34)} LEAK  ${hits.length} capture file(s): ${hits.slice(0, 3).join(", ")}${hits.length > 3 ? " …" : ""}`);
      } else {
        console.log(`  ${name.padEnd(34)} clean (${paths.length} files inspected)`);
      }
    } catch (e) {
      bad++; errored++;
      console.log(`  ${name.padEnd(34)} ERROR ${e.message}  <-- not counted as clean`);
    }
  }
}

console.log(`\nchecked ${checked} ref(s); ${bad} leaking or unverified.`);
if (checked === 0) { console.log("nothing was checked - that is a failure, not a pass."); process.exit(1); }
process.exit(bad ? 1 : 0);
