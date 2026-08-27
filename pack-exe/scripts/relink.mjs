#!/usr/bin/env node
/**
 * Repair junction links after the dsh-app bundle has been moved to a new
 * path or machine. Junction targets are absolute paths recorded at build
 * time; once the bundle moves, they dangle. This script rebuilds every
 * junction from the relative linkmap written by copy-links.mjs.
 *
 * Orphan links whose target package was dropped by packaging post-cleanup
 * (e.g. codex, claude-agent-sdk, mermaid) are removed silently; they are
 * not failures because no runtime code references them.
 *
 * usage: node relink.mjs <repoDir> <manifestFile>
 */

import { lstatSync, mkdirSync, readdirSync, readlinkSync, rmdirSync, symlinkSync, unlinkSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

const [, , repoArg, manifestArg] = process.argv
if (!repoArg || !manifestArg) {
  console.error('usage: node relink.mjs <repoDir> <manifestFile>')
  process.exit(1)
}

const repoDir = resolve(repoArg)
let manifest
try {
  manifest = JSON.parse(readFileSync(manifestArg, 'utf8'))
} catch (error) {
  console.error(`relink: cannot read manifest ${manifestArg}: ${error.message}`)
  process.exit(1)
}
if (typeof manifest.links !== 'object' || manifest.links === null) {
  console.error('relink: manifest has no links section')
  process.exit(1)
}

const toLocal = (rel) => join(repoDir, ...rel.split('/'))

// Windows junctions may carry a \\?\ prefix; strip it for path comparison.
const stripPrefix = (p) => p.replace(/^\\\\\?\\/, '')

let fixed = 0
let ok = 0
let cleaned = 0
const failures = []

for (const [linkRel, targetRel] of Object.entries(manifest.links)) {
  const link = toLocal(linkRel)
  const target = toLocal(targetRel)
  try {
    let existing
    try {
      existing = lstatSync(link)
    } catch {
      existing = undefined // link missing entirely
    }

    let stale = false
    if (existing === undefined) {
      stale = true
    } else if (!existing.isSymbolicLink()) {
      stale = true // real directory left where a junction belongs
    } else {
      // Compare the recorded target with the current one, case-insensitively
      // (Windows paths are case-insensitive).
      const current = stripPrefix(readlinkSync(link))
      if (resolve(current).toLowerCase() !== target.toLowerCase()) {
        stale = true
      }
    }

    if (!stale) {
      // Junction points where expected. Its target may have been dropped by
      // packaging post-cleanup (orphan packages): remove the dangling link
      // and count it as cleaned, not as a failure.
      let targetStat
      try {
        targetStat = lstatSync(target)
      } catch {
        targetStat = undefined
      }
      if (targetStat === undefined) {
        unlinkSync(link)
        cleaned++
        continue
      }
      ok++
      continue
    }

    // Clear whatever occupies the link path, then recreate the junction.
    if (existing !== undefined) {
      if (existing.isSymbolicLink()) {
        unlinkSync(link)
      } else if (existing.isDirectory()) {
        const children = readdirSync(link)
        if (children.length > 0) {
          failures.push(`${linkRel}: non-empty directory in the way`)
          continue
        }
        rmdirSync(link)
      } else {
        unlinkSync(link)
      }
    }
    mkdirSync(dirname(link), { recursive: true })
    symlinkSync(target, link, 'junction')
    fixed++
  } catch (error) {
    failures.push(`${linkRel}: ${error.message}`)
  }
}

console.log(`relink: ${fixed} repaired, ${ok} already correct, ${cleaned} orphan links removed`)
for (const failure of failures) {
  console.warn(`  ${failure}`)
}
process.exitCode = failures.length > 0 ? 1 : 0
