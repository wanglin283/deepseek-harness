#!/usr/bin/env node
/**
 * Recreate directory junctions (reparse points) under a copied node_modules
 * tree. robocopy copies real files but skips junctions (/XJ), so every
 * junction must be recreated at its counterpart path.
 *
 * Junction targets inside the source repository root are remapped onto the
 * destination repository root; anything else is reported as a warning and
 * left out.
 *
 * With a manifest file (optional 5th argument), every recreated junction is
 * recorded as a relative link -> relative target pair. The app later uses
 * this manifest (relink.mjs) to repair junctions after the bundle is moved
 * to a different machine/path, where the absolute targets recorded here
 * would otherwise dangle.
 *
 * usage: node copy-links.mjs <srcRoot> <dstRoot> <srcDir> <dstDir> [manifestFile]
 */

import { lstatSync, mkdirSync, readdirSync, readlinkSync, rmdirSync, symlinkSync, unlinkSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'

const [, , srcRootArg, dstRootArg, srcDirArg, dstDirArg, manifestArg] = process.argv
if (!srcRootArg || !dstRootArg || !srcDirArg || !dstDirArg) {
  console.error('usage: node copy-links.mjs <srcRoot> <dstRoot> <srcDir> <dstDir> [manifestFile]')
  process.exit(1)
}

const srcRoot = resolve(srcRootArg)
const dstRoot = resolve(dstRootArg)
const srcDir = resolve(srcDirArg)
const dstDir = resolve(dstDirArg)

const toPosix = (p) => p.split(sep).join('/')

// Manifest: { links: { "<linkRelPath>": "<targetRelPath>" } }, both relative
// to dstRoot and slash-separated. Accumulates across invocations.
let manifest = { links: {} }
if (manifestArg) {
  try {
    manifest = JSON.parse(readFileSync(manifestArg, 'utf8'))
    if (typeof manifest.links !== 'object' || manifest.links === null) manifest = { links: {} }
  } catch {
    manifest = { links: {} }
  }
}

let created = 0
const warnings = []

/** Map a junction target onto the destination root, or null when unmappable. */
function mapTarget(target, linkDir) {
  // Windows junctions may carry a \\?\ prefix; strip it for path arithmetic.
  const cleaned = target.replace(/^\\\\\?\\/, '')
  const abs = resolve(linkDir, cleaned)
  if (abs === srcRoot || abs.startsWith(srcRoot + sep)) {
    return join(dstRoot, relative(srcRoot, abs))
  }
  return null
}

function walk(dir) {
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const entry of entries) {
    const path = join(dir, entry.name)
    let stat
    try {
      stat = lstatSync(path)
    } catch {
      continue
    }
    if (stat.isSymbolicLink()) {
      const rel = relative(srcDir, path)
      const dstLink = join(dstDir, rel)
      try {
        const target = readlinkSync(path)
        const mapped = mapTarget(target, dirname(path))
        if (mapped === null) {
          warnings.push(`unmapped target, skipped: ${path} -> ${target}`)
          continue
        }
        mkdirSync(dirname(dstLink), { recursive: true })
        // robocopy leaves an empty directory where it skipped a junction, and
        // reruns may find a previous junction: clear either before linking.
        let existing
        try {
          existing = lstatSync(dstLink)
        } catch {
          // absent - fine
        }
        if (existing) {
          if (existing.isSymbolicLink()) {
            unlinkSync(dstLink)
          } else if (existing.isDirectory()) {
            const children = readdirSync(dstLink)
            if (children.length > 0) {
              warnings.push(`non-empty directory exists, skipped: ${dstLink}`)
              continue
            }
            rmdirSync(dstLink)
          } else {
            warnings.push(`file exists, skipped: ${dstLink}`)
            continue
          }
        }
        symlinkSync(mapped, dstLink, 'junction')
        created++
        if (manifestArg) {
          manifest.links[toPosix(relative(dstRoot, dstLink))] = toPosix(relative(dstRoot, mapped))
        }
      } catch (error) {
        warnings.push(`failed to recreate ${path}: ${error.message}`)
      }
    } else if (stat.isDirectory()) {
      walk(path)
    }
  }
}

walk(srcDir)
console.log(`copy-links: ${created} junction(s) recreated under ${dstDir}`)
for (const warning of warnings) {
  console.warn(`  ${warning}`)
}
if (manifestArg) {
  writeFileSync(manifestArg, JSON.stringify(manifest, null, 2))
  console.log(`copy-links: manifest written (${Object.keys(manifest.links).length} entries)`)
}
if (warnings.length > 0) {
  process.exitCode = 1
}
