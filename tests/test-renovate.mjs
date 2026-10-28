// Run inside the Renovate image: exercise its real parser, RE2 regex manager,
// replacement engine, package rules, and custom datasource schema offline.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = process.env.RENOVATE_PACKAGE_ROOT ?? '/usr/local/renovate/dist';
const load = (file) => import(pathToFileURL(path.join(root, file)));
const { init } = await load('logger/index.js');
await init();
const { extractPackageFile } = await load('modules/manager/custom/regex/index.js');
const { parseTomlFile } = await load('modules/manager/mise/utils.js');
const { applyPackageRules } = await load('util/package-rules/index.js');
const { CustomDatasource } = await load('modules/datasource/custom/index.js');
const { doAutoReplace } = await load('workers/repository/update/branch/auto-replace.js');
const { GlobalConfig } = await load('config/global.js');
const temporaryRepo = await fs.mkdtemp(path.join(os.tmpdir(), 'renovate-coverage-'));
GlobalConfig.set({ localDir: temporaryRepo, platform: 'local' });
process.on('exit', () => {
  // All replacement writes stay in this temporary repository.
  rmSync(temporaryRepo, { recursive: true, force: true });
});

const base = JSON.parse(await fs.readFile('renovate-base.json', 'utf8'));
const config = JSON.parse(await fs.readFile('renovate.json', 'utf8'));
const content = await fs.readFile('mise.toml', 'utf8');
const manifest = parseTomlFile(content, 'mise.toml');
assert.ok(manifest, 'mise.toml must parse');
const deps = config.customManagers.flatMap((manager) => {
  if (!manager.managerFilePatterns.includes('/^mise\\.toml$/')) return [];
  const result = extractPackageFile(content, 'mise.toml', manager);
  return (result?.deps ?? []).map((dep, depIndex) => ({ ...manager, ...result, ...dep, depIndex }));
});
const rules = [...base.packageRules, ...config.packageRules];
const route = (dep, updateType = 'minor', manager = 'custom.regex') => applyPackageRules({
  ...base, ...dep, packageName: dep.depName, manager, packageFile: 'mise.toml', updateType, packageRules: rules,
});

for (const [tool, value] of Object.entries(manifest.tools)) {
  if (!tool.startsWith('http:')) continue;
  // Match the independently parsed tool version back to exactly one real
  // extraction record: missing annotations or regex drift must fail CI.
  const block = `[tools."${tool}"]\nversion = "${value.version}"`;
  const matches = deps.filter((dep) => dep.replaceString.includes(block));
  assert.equal(matches.length, 1, `${tool} must be extracted once`);
  const dep = matches[0];
  assert.equal(dep.currentValue, value.version);
  assert.ok(dep.datasource && !dep.skipReason, `${tool} must have a datasource`);
  const policy = await route(dep);
  assert.equal(policy.groupName, 'mise-managed cli tools', tool);
  assert.equal(policy.automerge, false, `${tool} must use lockfile preparation`);
  assert.equal(policy.minimumReleaseAge, '10 days', tool);
  const upgraded = await doAutoReplace({ ...dep, manager: 'regex',
    packageFile: 'mise.toml', newValue: '99.99.99' }, content, false);
  assert.ok(upgraded.includes(`[tools."${tool}"]\nversion = "99.99.99"`), tool);
}

const anchor = deps.find((dep) => dep.depName === 'aquaproj/aqua-registry');
assert.ok(anchor, 'aqua registry must be extracted');
assert.match(anchor.currentDigest, /^[a-f0-9]{40}$/);
assert.ok(content.includes(`/${anchor.currentDigest}/registry.yaml`));
const anchorPolicy = await route(anchor);
assert.equal(anchorPolicy.groupName, 'aqua-registry SHA pin (trust anchor)');
assert.equal(anchorPolicy.automerge, false, 'registry trust anchor needs review');
const nextDigest = '0123456789abcdef0123456789abcdef01234567';
const upgradedAnchor = await doAutoReplace({ ...anchor, manager: 'regex',
  packageFile: 'mise.toml', newValue: 'v99.99.99', newDigest: nextDigest }, content, false);
assert.ok(upgradedAnchor.includes(`/${nextDigest}/registry.yaml" # v99.99.99`));
assert.ok(!upgradedAnchor.includes(anchor.currentDigest));
const lockPolicy = await route({ depName: 'gh' }, 'lockFileMaintenance', 'mise');
assert.equal(lockPolicy.automerge, true, 'lock-only maintenance remains self-contained');

// Include misleading text plus the upstream's indentation and CRLF format.
// A missing Created line must not become an undated release that can silently
// bypass or indefinitely pend the supply-chain age gate.
const datasource = new CustomDatasource();
for (const newline of ['\n', '\r\n']) {
  datasource.http.getPlain = async () => ({ body: [
    'Client tools for OpenShift', 'Component Version: 1.2.3',
    'Created:        2026-09-17T15:25:32Z',
    'Release Metadata:', '  Version:  4.21.34',
  ].join(newline) });
  const result = await datasource.getReleases({ datasource: 'custom.openshift-mirror',
    packageName: 'openshift/oc', customDatasources: base.customDatasources });
  assert.deepEqual(result.releases.map(({ version, releaseTimestamp }) =>
    ({ version, releaseTimestamp })), [{ version: '4.21.34',
    releaseTimestamp: '2026-09-17T15:25:32.000Z' }]);
}
datasource.http.getPlain = async () => ({ body: '  Version: 4.21.34\n' });
assert.equal(await datasource.getReleases({ datasource: 'custom.openshift-mirror',
  packageName: 'openshift/oc', customDatasources: base.customDatasources }), null);

// Real local git history: only known preparation authors may be overwritten
// by Renovate; an ordinary human edit must still freeze the branch.
const gitModule = await load('util/git/index.js');
const seed = path.join(temporaryRepo, 'seed');
await fs.mkdir(seed);
const git = (...args) => execFileSync('git', args, { cwd: seed,
  stdio: 'pipe', env: { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_CONFIG_SYSTEM: '/dev/null' } });
git('init', '-b', 'main');
git('config', 'user.name', 'Renovate coverage test');
git('config', 'user.email', 'renovate@example.invalid');
git('commit', '--allow-empty', '-m', 'base');
const authors = new Map([['generated', 'dependency-preparation@igou-devenv.invalid'],
  ['legacy', '41898282+github-actions[bot]@users.noreply.github.com'],
  ['human', 'human@example.invalid']]);
for (const [branch, email] of authors) {
  git('checkout', '-b', `renovate/${branch}`, 'main');
  git('config', 'user.email', email);
  git('commit', '--allow-empty', '-m', branch);
}
git('checkout', 'main');
const remote = path.join(temporaryRepo, 'remote.git');
git('clone', '--bare', seed, remote);
const checkout = path.join(temporaryRepo, 'checkout');
await fs.mkdir(checkout);
GlobalConfig.set({ localDir: checkout, platform: 'github' });
await gitModule.initRepo({ url: remote, defaultBranch: 'main' });
gitModule.setUserRepoConfig({ gitAuthor: 'Renovate <renovate@example.invalid>',
  gitIgnoredAuthors: config.gitIgnoredAuthors });
for (const [branch] of authors) {
  assert.equal(await gitModule.isBranchModified(`renovate/${branch}`, 'main'),
    branch === 'human', `Renovate rebase protection for ${branch}`);
}
console.log(`Renovate coverage passed: ${deps.length - 1} HTTP tools, aqua tag/SHA replacement, lock handoff, OpenShift version/date, generated vs human commits.`);
