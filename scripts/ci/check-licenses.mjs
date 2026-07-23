#!/usr/bin/env node
// Validate the licence of every npm dependency shipped in the frontend.
//
// Runs offline against the installed tree (app/node_modules) rather than a
// registry API, so it works without network access and reflects exactly what
// the build consumes. The policy itself lives in license-policy.json so it can
// be reviewed without reading code.
//
// Exit codes: 0 = pass, 1 = disallowed licence found, 2 = bad invocation.
//
// Usage:
//   node scripts/ci/check-licenses.mjs
//   node scripts/ci/check-licenses.mjs --strict   # exceptions no longer waive
//   node scripts/ci/check-licenses.mjs --json
import { readFileSync, readdirSync, existsSync, statSync, appendFileSync } from 'node:fs'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '../..')

const args = process.argv.slice(2)
const dirArg = args.indexOf('--dir')
const APP_DIR = resolve(ROOT, dirArg === -1 ? 'app' : (args[dirArg + 1] ?? 'app'))
const asJson = args.includes('--json')
const strict = args.includes('--strict')

const policy = JSON.parse(readFileSync(join(HERE, 'license-policy.json'), 'utf8'))
const ALLOWED = new Set(policy.allowed)
const DENIED = new Set(policy.denied)
const EXCEPTIONS = new Map(policy.exceptions.map((e) => [e.package, e]))
const REVIEWED = new Set(Object.keys(policy.reviewed ?? {}).filter((k) => !k.startsWith('$')))

function normalise(license) {
  if (!license) return null
  if (typeof license === 'string') return license
  if (Array.isArray(license)) {
    return license.map(normalise).filter(Boolean).join(' OR ') || null
  }
  if (typeof license === 'object' && license.type) return license.type
  return null
}

// Split a licence expression into individual identifiers. Handles SPDX
// ("MIT OR Apache-2.0", "(MIT OR Apache-2.0) AND Unicode-3.0") plus the legacy
// slash form crates.io still carries ("MIT/Apache-2.0"), and drops the
// `WITH <exception>` suffix — an exception only ever widens permissions.
function terms(expr) {
  return expr
    .replace(/[()]/g, ' ')
    .replace(/\s+WITH\s+[\w.-]+/gi, '')
    .split(/\s+(?:OR|AND)\s+|\//i)
    .map((t) => t.trim().replace(/\+$/, ''))
    .filter(Boolean)
}

function classify(expr) {
  if (!expr) return 'unknown'
  const parts = terms(expr)
  if (parts.some((p) => DENIED.has(p))) return 'denied'
  // A choice of licences is satisfied if any branch is acceptable.
  const isChoice = /\bOR\b/i.test(expr) || expr.includes('/')
  if (isChoice) return parts.some((p) => ALLOWED.has(p)) ? 'allowed' : 'unknown'
  return parts.every((p) => ALLOWED.has(p)) ? 'allowed' : 'unknown'
}

function* walkModules(dir) {
  if (!existsSync(dir)) return
  for (const entry of readdirSync(dir)) {
    if (entry === '.bin' || entry === '.package-lock.json') continue
    const full = join(dir, entry)
    let stats
    try {
      stats = statSync(full)
    } catch {
      continue
    }
    if (!stats.isDirectory()) continue

    if (entry.startsWith('@')) {
      for (const scoped of readdirSync(full)) {
        const scopedPath = join(full, scoped)
        if (statSync(scopedPath).isDirectory()) {
          yield scopedPath
          yield* walkModules(join(scopedPath, 'node_modules'))
        }
      }
      continue
    }
    yield full
    yield* walkModules(join(full, 'node_modules'))
  }
}

function collectNpm() {
  const found = new Map()
  for (const path of walkModules(join(APP_DIR, 'node_modules'))) {
    const pkgPath = join(path, 'package.json')
    if (!existsSync(pkgPath)) continue
    try {
      const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'))
      if (!pkg.name || !pkg.version) continue
      found.set(`${pkg.name}@${pkg.version}`, {
        name: pkg.name,
        license: normalise(pkg.license ?? pkg.licenses),
      })
    } catch {
      // Unparseable metadata is reported as unknown rather than skipped.
      found.set(path, { name: path, license: null })
    }
  }
  if (found.size === 0) {
    console.error(`✗ no packages found under ${APP_DIR}/node_modules — run 'npm ci' first`)
    process.exit(1)
  }
  return found
}

function collectCargo() {
  const found = new Map()
  const out = execFileSync('cargo', ['metadata', '--format-version', '1', '--locked'], {
    cwd: ROOT,
    encoding: 'utf8',
    maxBuffer: 128 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'inherit'],
  })
  const meta = JSON.parse(out)
  // Workspace members are this repo's own code, governed by /LICENSE.
  const local = new Set(meta.workspace_members)
  for (const pkg of meta.packages) {
    if (local.has(pkg.id)) continue
    found.set(`${pkg.name}@${pkg.version}`, { name: pkg.name, license: pkg.license ?? null })
  }
  return found
}

const ecosystemArg = args.indexOf('--ecosystem')
const ecosystem = ecosystemArg === -1 ? 'npm' : (args[ecosystemArg + 1] ?? 'npm')

const packages = new Map()
if (ecosystem === 'npm' || ecosystem === 'all') {
  for (const [k, v] of collectNpm()) packages.set(k, v)
}
if (ecosystem === 'cargo' || ecosystem === 'all') {
  for (const [k, v] of collectCargo()) packages.set(k, v)
}
if (!['npm', 'cargo', 'all'].includes(ecosystem)) {
  console.error(`✗ unknown --ecosystem "${ecosystem}" (expected npm, cargo or all)`)
  process.exit(2)
}

const denied = []
const waived = []
const unknown = []
const counts = new Map()

for (const [id, { name, license }] of [...packages].sort()) {
  counts.set(license ?? 'UNKNOWN', (counts.get(license ?? 'UNKNOWN') ?? 0) + 1)

  const verdict = REVIEWED.has(name) ? 'allowed' : classify(license)
  if (verdict === 'denied') {
    const exception = EXCEPTIONS.get(name)
    if (exception && !strict) {
      const expired = exception.review_by && new Date(exception.review_by) < new Date()
      waived.push({ id, license, expired, reason: exception.reason })
      if (expired) denied.push({ id, license, note: `exception expired ${exception.review_by}` })
    } else {
      denied.push({ id, license })
    }
  } else if (verdict === 'unknown') {
    unknown.push({ id, license: license ?? 'UNKNOWN' })
  }
}

const scope =
  ecosystem === 'cargo'
    ? 'cargo dependencies'
    : ecosystem === 'all'
      ? 'npm + cargo dependencies'
      : `npm packages under ${APP_DIR}/node_modules`
console.log(`→ checked ${packages.size} ${scope}`)
for (const [license, count] of [...counts].sort((a, b) => b[1] - a[1]).slice(0, 8)) {
  console.log(`   ${String(count).padStart(4)}  ${license}`)
}

if (unknown.length) {
  console.log(`\n⚠  ${unknown.length} package(s) with an unrecognised licence expression:`)
  for (const u of unknown.slice(0, 20)) console.log(`   ${u.id}  →  ${u.license}`)
  if (unknown.length > 20) console.log(`   … and ${unknown.length - 20} more`)
  console.log('   Add the SPDX id to "allowed", or the package to "reviewed", in license-policy.json.')
}

if (waived.length) {
  console.log(`\n⚠  ${waived.length} copyleft package(s) waived by a tracked exception:`)
  for (const w of waived) {
    console.log(`   ${w.id}  →  ${w.license}${w.expired ? '  [EXCEPTION EXPIRED]' : ''}`)
    console.log(`     ${w.reason}`)
  }
}

// Unknown licences are surfaced but never fail the build: the npm ecosystem has
// enough non-SPDX metadata ("SEE LICENSE IN ...") that failing on it produces
// noise rather than safety. Denied licences always fail.
if (denied.length) {
  console.error(`\n✗ ${denied.length} package(s) under a disallowed licence:`)
  for (const d of denied) {
    console.error(`   ${d.id}  →  ${d.license}${d.note ? `  (${d.note})` : ''}`)
  }
  console.error(`\n  This repo is distributed under Apache-2.0; these licences are incompatible.`)
  console.error(`  Resolve by removing the dependency, overriding it to a compatible version,`)
  console.error(`  or adding a justified entry to scripts/ci/license-policy.json.`)
  process.exit(1)
}

const summary = [
  `- Packages scanned: **${packages.size}**`,
  `- Disallowed: **0**`,
  `- Waived by exception: **${waived.length}**`,
  `- Unrecognised expression: **${unknown.length}**`,
].join('\n')

if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(process.env.GITHUB_STEP_SUMMARY, `### Dependency licences\n${summary}\n`)
}

if (asJson) {
  console.log(JSON.stringify({ total: packages.size, denied, waived, unknown }, null, 2))
}

console.log('\n✓ no disallowed licences')
