import { expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

const initializer = fs.readFileSync(
    path.resolve(__dirname, '../../docker/package-init.sh'),
    'utf8'
);

for (const oldRuntimeExists of [false, true]) {
    test(`cached PVC refreshes Node and Bun launchers with ${
        oldRuntimeExists ? 'retained' : 'removed'
    } old runtimes`, () => {
        const root = fs.mkdtempSync(
            path.join(os.tmpdir(), 'cached-package-init-')
        );
        try {
            const packages = path.join(root, 'pkgs');
            const workspace = path.join(root, 'workspace');
            const manifest = path.join(root, 'javascript-packages.txt');
            fs.mkdirSync(workspace);
            fs.writeFileSync(manifest, 'runtime-fixture@1.0.0\n');
            const runtimes = [
                {
                    directory: 'node/24.22.1',
                    binary: 'bin/node',
                    args: ['hello world', '--version'],
                },
                {
                    directory: 'bun/1.4.4',
                    binary: 'bun',
                    args: ['run', 'hello world', '--version'],
                },
            ];
            for (const runtime of runtimes) {
                const destination = path.join(packages, runtime.directory);
                const fixture = path.join(
                    destination,
                    'node_modules/runtime-fixture'
                );
                fs.mkdirSync(fixture, { recursive: true });
                fs.mkdirSync(
                    path.dirname(path.join(destination, runtime.binary)),
                    { recursive: true }
                );
                fs.writeFileSync(
                    path.join(fixture, 'package.json'),
                    '{"version": "1.0.0"}'
                );
                fs.writeFileSync(
                    path.join(destination, '.package-installed'),
                    'installed'
                );
                fs.writeFileSync(
                    path.join(destination, '.env'),
                    'preserve runtime environment'
                );
                fs.writeFileSync(
                    path.join(destination, runtime.binary),
                    '#!/bin/bash\nprintf "<%s>\\n" "$@"\n',
                    { mode: 0o755 }
                );
                fs.writeFileSync(
                    path.join(destination, 'run'),
                    '#!/bin/bash\nexit 99\n',
                    { mode: 0o755 }
                );
            }
            const python = path.join(packages, 'python/3.14.4');
            for (const name of [
                'PIL',
                'markitdown',
                'chdb',
                'statsmodels',
                'rasterio',
            ]) {
                fs.mkdirSync(
                    path.join(python, 'lib/python3.14/site-packages', name),
                    { recursive: true }
                );
            }
            fs.writeFileSync(
                path.join(python, 'lib/python3.14/.sandbox-pipe-runtime-v1'),
                'installed'
            );
            fs.writeFileSync(
                path.join(python, '.package-installed'),
                'installed'
            );
            fs.mkdirSync(path.join(packages, 'bash/5.2.0'), {
                recursive: true,
            });
            fs.writeFileSync(
                path.join(packages, 'bash/5.2.0/.package-installed'),
                'installed'
            );
            fs.mkdirSync(path.join(packages, 'r/4.5.2'), {
                recursive: true,
            });
            fs.writeFileSync(
                path.join(packages, 'r/4.5.2/.package-installed'),
                'installed'
            );
            fs.writeFileSync(
                path.join(packages, '.initialized'),
                'original initialization'
            );

            const forbidden = path.join(root, 'forbidden');
            fs.mkdirSync(forbidden);
            for (const binary of [
                'curl',
                'wget',
                'make',
                'npm',
                'tar',
                'unzip',
            ]) {
                fs.writeFileSync(
                    path.join(forbidden, binary),
                    '#!/bin/bash\necho "unexpected reinstall" >&2\nexit 98\n',
                    { mode: 0o755 }
                );
            }
            const script = path.join(root, 'package-init.sh');
            fs.writeFileSync(
                script,
                initializer
                    .split('/pkgs')
                    .join(packages)
                    .split('/mnt/data/node_modules')
                    .join(path.join(workspace, 'node_modules'))
            );
            const env = {
                ...process.env,
                PATH: `${forbidden}:${process.env.PATH}`,
                FORCE_REBUILD: 'false',
                PYTHON_VERSION: '3.14.4',
                NODE_VERSION: '24.22.1',
                BUN_VERSION: '1.4.4',
                BASH_PACKAGE_VERSION: '5.2.0',
                R_VERSION: '4.5.2',
                JS_PACKAGE_MANIFEST: manifest,
            };
            for (let pass = 0; pass < 2; pass += 1) {
                const initialized = Bun.spawnSync({
                    cmd: ['bash', script],
                    env,
                });
                expect(initialized.stderr.toString()).toBe('');
                expect(initialized.exitCode).toBe(0);
                expect(initialized.stdout.toString()).toContain(
                    'Packages already initialized'
                );
                expect(
                    fs.readFileSync(path.join(packages, '.initialized'), 'utf8')
                ).toBe('original initialization');
                for (const runtime of runtimes) {
                    const destination = path.join(packages, runtime.directory);
                    const oldModules = path.join(
                        packages,
                        runtime.directory.split('/')[0],
                        '0.0.1/node_modules'
                    );
                    if (oldRuntimeExists)
                        fs.mkdirSync(oldModules, { recursive: true });
                    const link = path.join(workspace, 'node_modules');
                    fs.rmSync(link, { force: true });
                    fs.symlinkSync(oldModules, link);
                    const launched = Bun.spawnSync({
                        cmd: [
                            path.join(destination, 'run'),
                            'hello world',
                            '--version',
                        ],
                    });
                    expect(launched.stderr.toString()).toBe('');
                    expect(launched.exitCode).toBe(0);
                    expect(launched.stdout.toString()).toBe(
                        runtime.args.map(arg => `<${arg}>\n`).join('')
                    );
                    expect(fs.readlinkSync(link)).toBe(
                        path.join(destination, 'node_modules')
                    );
                    expect(
                        fs.readFileSync(
                            path.join(destination, '.package-installed'),
                            'utf8'
                        )
                    ).toBe('installed');
                    expect(
                        fs.readFileSync(path.join(destination, '.env'), 'utf8')
                    ).toBe('preserve runtime environment');
                    expect(
                        fs
                            .readdirSync(destination)
                            .some(name => name.startsWith('.run.'))
                    ).toBe(false);
                }
            }
        } finally {
            fs.rmSync(root, { recursive: true, force: true });
        }
    });
}

/** Seed a /pkgs tree that satisfies every readiness probe in
 * `packages_ready`, optionally omitting one runtime so the caller can assert
 * that its absence alone re-opens the install path. */
function seedReadyPackages(packages: string, omit?: 'r'): void {
    const python = path.join(packages, 'python/3.14.4');
    for (const name of ['PIL', 'markitdown', 'chdb', 'statsmodels', 'rasterio']) {
        fs.mkdirSync(path.join(python, 'lib/python3.14/site-packages', name), {
            recursive: true,
        });
    }
    fs.writeFileSync(
        path.join(python, 'lib/python3.14/.sandbox-pipe-runtime-v1'),
        'installed'
    );
    fs.writeFileSync(path.join(python, '.package-installed'), 'installed');

    for (const directory of ['node/24.22.1', 'bun/1.4.4']) {
        const destination = path.join(packages, directory);
        const module = path.join(destination, 'node_modules/runtime-fixture');
        fs.mkdirSync(module, { recursive: true });
        fs.writeFileSync(
            path.join(module, 'package.json'),
            '{ "name": "runtime-fixture", "version": "1.0.0" }'
        );
        fs.writeFileSync(
            path.join(destination, '.package-installed'),
            'installed'
        );
    }
    for (const directory of ['bash/5.2.0', 'r/4.5.2']) {
        if (omit === 'r' && directory.startsWith('r/')) continue;
        fs.mkdirSync(path.join(packages, directory), { recursive: true });
        fs.writeFileSync(
            path.join(packages, directory, '.package-installed'),
            'installed'
        );
    }
    fs.writeFileSync(path.join(packages, '.initialized'), 'original');
}

/** A PVC provisioned before R was added still carries a valid `.initialized`
 * marker. If `packages_ready` ignored R, that cache would be reported ready
 * forever and the R runtime would never be installed — every R job would then
 * fail to resolve a runtime, with nothing in the init logs to explain it. */
test('a cached PVC without R is not treated as ready', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'r-gap-package-init-'));
    try {
        const packages = path.join(root, 'pkgs');
        const workspace = path.join(root, 'workspace');
        const manifest = path.join(root, 'javascript-packages.txt');
        fs.mkdirSync(workspace, { recursive: true });
        fs.writeFileSync(manifest, 'runtime-fixture@1.0.0\n');

        const script = path.join(root, 'package-init.sh');
        fs.writeFileSync(
            script,
            initializer
                .split('/pkgs')
                .join(packages)
                .split('/mnt/data/node_modules')
                .join(path.join(workspace, 'node_modules'))
        );

        // Nothing may reach the network: reaching the install path at all is
        // the signal under test, so stop it there rather than downloading R.
        const forbidden = path.join(root, 'forbidden');
        fs.mkdirSync(forbidden);
        for (const binary of ['curl', 'wget', 'make', 'npm', 'tar', 'unzip']) {
            fs.writeFileSync(
                path.join(forbidden, binary),
                '#!/bin/bash\nexit 98\n',
                { mode: 0o755 }
            );
        }

        const env = {
            ...process.env,
            PATH: `${forbidden}:${process.env.PATH}`,
            FORCE_REBUILD: 'false',
            PYTHON_VERSION: '3.14.4',
            NODE_VERSION: '24.22.1',
            BUN_VERSION: '1.4.4',
            BASH_PACKAGE_VERSION: '5.2.0',
            R_VERSION: '4.5.2',
            JS_PACKAGE_MANIFEST: manifest,
        };

        // Control: the same tree WITH R takes the cached path.
        seedReadyPackages(packages);
        const ready = Bun.spawnSync({ cmd: ['bash', script], env });
        expect(ready.stdout.toString()).toContain(
            'Packages already initialized'
        );
        expect(ready.exitCode).toBe(0);

        // Same tree, R removed: the cached path must no longer be taken.
        fs.rmSync(packages, { recursive: true, force: true });
        seedReadyPackages(packages, 'r');
        const stale = Bun.spawnSync({ cmd: ['bash', script], env });
        expect(stale.stdout.toString()).not.toContain(
            'Packages already initialized'
        );
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});
