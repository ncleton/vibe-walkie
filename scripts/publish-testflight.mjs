#!/usr/bin/env node

import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";

const required = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY_PATH"];
for (const name of required) {
  if (!process.env[name]) throw new Error(`${name} est obligatoire.`);
}

const args = new Set(process.argv.slice(2));
const assign = args.has("--assign");
const wait = args.has("--wait") || assign;
const buildNumber = process.env.BUILD_NUMBER;
if (!buildNumber) throw new Error("BUILD_NUMBER est obligatoire.");

const bundleId = process.env.BUNDLE_ID ?? "app.vibewalkie";
const wantedGroups = (process.env.TESTFLIGHT_GROUPS ?? "Équipe Vibe Walkie")
  .split(",")
  .map((name) => name.trim())
  .filter(Boolean);
const timeoutMs = Number(process.env.TESTFLIGHT_PROCESSING_TIMEOUT_MS ?? 45 * 60 * 1000);
const pollMs = Number(process.env.TESTFLIGHT_POLL_INTERVAL_MS ?? 30_000);

const base64url = (value) => Buffer.from(value).toString("base64url");

function token() {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "ES256", kid: process.env.ASC_KEY_ID, typ: "JWT" }));
  const payload = base64url(JSON.stringify({
    iss: process.env.ASC_ISSUER_ID,
    iat: now,
    exp: now + 15 * 60,
    aud: "appstoreconnect-v1",
  }));
  const unsigned = `${header}.${payload}`;
  const signer = createSign("SHA256");
  signer.update(unsigned);
  signer.end();
  const signature = signer.sign({
    key: readFileSync(process.env.ASC_PRIVATE_KEY_PATH),
    dsaEncoding: "ieee-p1363",
  });
  return `${unsigned}.${signature.toString("base64url")}`;
}

async function request(path, options = {}) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token()}`,
      "Content-Type": "application/json",
      ...(options.headers ?? {}),
    },
  });
  const text = await response.text();
  if (!response.ok) {
    let detail = text;
    try {
      const json = JSON.parse(text);
      detail = json.errors?.map((error) => error.detail ?? error.title).join(" | ") ?? text;
    } catch {}
    throw new Error(`${options.method ?? "GET"} ${path}: HTTP ${response.status} - ${detail}`);
  }
  return text ? JSON.parse(text) : null;
}

async function one(path, label) {
  const response = await request(path);
  if (response.data?.length !== 1) {
    throw new Error(`${label}: ${response.data?.length ?? 0} résultat(s), un seul attendu.`);
  }
  return response.data[0];
}

const app = await one(`/v1/apps?filter[bundleId]=${encodeURIComponent(bundleId)}&limit=2`, `App ${bundleId}`);

async function findBuild() {
  const path = `/v1/builds?filter[app]=${encodeURIComponent(app.id)}&filter[version]=${encodeURIComponent(buildNumber)}&limit=2`;
  const response = await request(path);
  if (response.data?.length > 1) throw new Error(`Build ${buildNumber}: plusieurs résultats inattendus.`);
  return response.data?.[0] ?? null;
}

const deadline = Date.now() + timeoutMs;
let build = await findBuild();
while (wait && (!build || build.attributes.processingState === "PROCESSING") && Date.now() < deadline) {
  console.log(build
    ? `Build ${buildNumber}: traitement Apple en cours…`
    : `Build ${buildNumber}: pas encore visible dans App Store Connect…`);
  await new Promise((resolve) => setTimeout(resolve, pollMs));
  build = await findBuild();
}

if (!build) throw new Error(`Build ${buildNumber} introuvable dans App Store Connect.`);
const state = build.attributes.processingState;
console.log(`Build ${buildNumber}: ${state}`);
if (state !== "VALID") {
  throw new Error(`Le build ${buildNumber} n’est pas distribuable (état ${state}).`);
}

const groupsResponse = await request(`/v1/betaGroups?filter[app]=${encodeURIComponent(app.id)}&limit=200`);
const groupsByName = new Map(groupsResponse.data.map((group) => [group.attributes.name, group]));
const groups = wantedGroups.map((name) => {
  const group = groupsByName.get(name);
  if (!group) throw new Error(`Groupe TestFlight introuvable : ${name}`);
  return group;
});

if (assign) {
  // App Store Connect refuse d’ajouter explicitement un groupe interne : les
  // groupes internes configurés pour tous les builds les reçoivent déjà
  // automatiquement. Seuls les groupes externes sont donc ajoutés ici.
  const externalGroups = groups.filter((group) => !group.attributes.isInternalGroup);
  if (externalGroups.length) {
    await request(`/v1/builds/${build.id}/relationships/betaGroups`, {
      method: "POST",
      body: JSON.stringify({
        data: externalGroups.map((group) => ({ type: "betaGroups", id: group.id })),
      }),
    });
  }
  console.log(`Build ${buildNumber}: groupes externes affectés, groupes internes gérés par Apple.`);
}

// La relation build → groupes n’autorise plus la lecture. Apple expose en
// revanche la relation groupe → builds, qui permet de vérifier les deux types
// de groupes sans supposer le comportement automatique des groupes internes.
const groupChecks = await Promise.all(groups.map(async (group) => {
  const linkedBuilds = await request(`/v1/betaGroups/${group.id}/relationships/builds?limit=200`);
  return {
    group,
    linked: linkedBuilds.data.some((linkedBuild) => linkedBuild.id === build.id),
  };
}));
const missing = groupChecks.filter((check) => !check.linked).map((check) => check.group);
if (missing.length) {
  throw new Error(`Affectation TestFlight incomplète : ${missing.map((group) => group.attributes.name).join(", ")}.`);
}

console.log(`TESTFLIGHT VERIFIED: ${bundleId} build ${buildNumber} - ${wantedGroups.join(" + ")}`);
