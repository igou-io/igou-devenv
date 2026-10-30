#!/usr/bin/env node
// Read Marketplace metadata without downloading or executing extension code.
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    config: { type: 'string', default: '.devcontainer/devcontainer.json' },
    output: { type: 'string' },
  },
});
const config = JSON.parse(await readFile(values.config, 'utf8'));
const pins = new Map();
for (const entry of config.customizations.vscode.extensions) {
  const match = /^([\w-]+\.[\w-]+)@(\d+\.\d+\.\d+)$/.exec(entry);
  if (!match) throw new Error(`Extension must have an exact version: ${entry}`);
  const id = match[1].toLowerCase();
  if (pins.has(id)) throw new Error(`Duplicate extension: ${id}`);
  pins.set(id, match[2]);
}

async function getJson(url, options) {
  const response = await fetch(url, {
    ...options,
    signal: AbortSignal.timeout(60_000),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${url}`);
  return response.json();
}

const gallery = await getJson(
  'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery',
  {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json;api-version=7.2-preview.1',
    },
    body: JSON.stringify({
      filters: [{
        criteria: [...pins.keys()].map(value => ({ filterType: 7, value })),
        pageNumber: 1,
        pageSize: pins.size,
        sortBy: 0,
        sortOrder: 0,
      }],
      assetTypes: ['Microsoft.VisualStudio.Code.Manifest'],
      // Versions, files, version properties, exclude unvalidated, asset URIs.
      flags: 1 | 2 | 16 | 32 | 128,
    }),
  },
);
const extensions = new Map(gallery.results.flatMap(result => result.extensions)
  .map(extension => [
    `${extension.publisher.publisherName}.${extension.extensionName}`.toLowerCase(),
    extension,
  ]));
const cutoff = Date.now() - 10 * 24 * 60 * 60 * 1000;
const feeds = new Map();

for (const [id, pinnedVersion] of pins) {
  const extension = extensions.get(id);
  if (!extension) throw new Error(`Extension unavailable in Marketplace: ${id}`);
  const releases = new Map();
  const variants = new Map();
  for (const version of extension.versions) {
    if (!/^\d+\.\d+\.\d+$/.test(version.version)) continue;
    if (version.properties?.some(property =>
      property.key === 'Microsoft.VisualStudio.Code.PreRelease' && property.value === 'true')) continue;
    if (version.targetPlatform && !['linux-x64', 'linux-arm64', 'universal'].includes(version.targetPlatform)) continue;
    const timestamp = Date.parse(version.lastUpdated);
    if (!Number.isFinite(timestamp)) throw new Error(`Missing publication date: ${id}@${version.version}`);
    const existing = releases.get(version.version);
    // Wait for the newest platform publication, so both Linux builds age out.
    if (!existing || timestamp > Date.parse(existing.releaseTimestamp)) {
      releases.set(version.version, {
        version: version.version,
        releaseTimestamp: new Date(timestamp).toISOString(),
        isStable: true,
      });
    }
    const platforms = variants.get(version.version) ?? [];
    platforms.push(version);
    variants.set(version.version, platforms);
  }
  for (const [version, platforms] of variants) {
    if (!platforms.some(platform => !platform.targetPlatform || platform.targetPlatform === 'universal') &&
        !['linux-x64', 'linux-arm64'].every(target => platforms.some(platform => platform.targetPlatform === target))) {
      releases.delete(version);
    }
  }
  const pinnedRelease = releases.get(pinnedVersion);
  if (!pinnedRelease) throw new Error(`Pin is not a stable release for both Linux architectures: ${id}@${pinnedVersion}`);
  if (Date.parse(pinnedRelease.releaseTimestamp) > cutoff) {
    throw new Error(`Pin is less than 10 days old: ${id}@${pinnedVersion}`);
  }
  // Check extension packs as well as required dependencies. New dependencies
  // must be pinned before a Renovate update can pass CI.
  for (const variant of variants.get(pinnedVersion)) {
    const manifestUrl = variant.files.find(file => file.assetType === 'Microsoft.VisualStudio.Code.Manifest')?.source;
    if (!manifestUrl) throw new Error(`Manifest unavailable: ${id}@${pinnedVersion}`);
    const manifest = await getJson(manifestUrl);
    if (`${manifest.publisher}.${manifest.name}`.toLowerCase() !== id || manifest.version !== pinnedVersion) {
      throw new Error(`Manifest does not match pin: ${id}@${pinnedVersion}`);
    }
    for (const dependency of [...(manifest.extensionDependencies ?? []), ...(manifest.extensionPack ?? [])]) {
      if (!pins.has(dependency.toLowerCase())) {
        throw new Error(`Unpinned dependency of ${id}@${pinnedVersion}: ${dependency}`);
      }
    }
  }
  feeds.set(id, {
    homepage: `https://marketplace.visualstudio.com/items?itemName=${id}`,
    releases: [...releases.values()].sort((a, b) => a.version.localeCompare(b.version, 'en', { numeric: true })),
  });
  console.log(`${id}@${pinnedVersion}: stable, at least 10 days old, dependencies pinned`);
}

// Write only after every pin and dependency has passed validation.
if (values.output) {
  const output = resolve(values.output);
  await mkdir(output, { recursive: true });
  for (const [id, feed] of feeds) {
    await writeFile(join(output, `${id}.json`), `${JSON.stringify(feed, null, 2)}\n`);
  }
}
