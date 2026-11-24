import { describe, expect, it } from 'bun:test';
import { readFileSync } from 'fs';
import * as path from 'path';
import {
  jobCompletionWaitTimeoutMs,
  jobDeadlineAtMs,
  languageConfig,
  lambdaMicrovmNumericConfigError,
  resolveEgressGrantTtlSeconds,
  resolveLanguage,
  resolveLambdaMicrovmNumericConfig,
} from './config';
import { Languages } from './enum';
import { createPayload } from './payload';
import type { AuthenticatedRequest } from './types';

describe('node language configuration', () => {
  it('resolves Node.js aliases', () => {
    for (const alias of ['node', 'nodejs', 'node-js', 'node-javascript']) {
      expect(resolveLanguage(alias)).toBe(Languages.node);
    }
  });

  it('maps Node.js requests to the node sandbox runtime', () => {
    expect(languageConfig[Languages.node]).toEqual({
      language: 'node',
      version: '24.22.1',
      fileName: 'index.js',
    });
  });

  it('aligns package installers and Helm with the selected Node runtime', () => {
    const root = path.resolve(__dirname, '../..');
    const version = languageConfig[Languages.node]!.version;
    for (const file of ['build-packages.sh', 'docker/package-init.sh']) {
      expect(readFileSync(path.join(root, file), 'utf8'))
        .toContain(`NODE_VERSION="\${NODE_VERSION:-${version}}"`);
    }
    expect(readFileSync(path.join(root, 'helm/codeapi/values.yaml'), 'utf8'))
      .toContain(`nodeVersion: "${version}"`);
  });

  it('creates a valid Node.js execution payload', () => {
    const req = {
      body: {
        lang: 'node',
        code: 'console.log("hello from node")',
        args: ['--trace-warnings'],
        files: [],
      },
    } as unknown as AuthenticatedRequest;

    const payload = createPayload({
      req,
      isPyPlot: false,
      session_id: 'session-node',
    });

    expect(payload).toMatchObject({
      language: 'node',
      version: '24.22.1',
      session_id: 'session-node',
      args: ['--trace-warnings'],
      files: [
        {
          name: 'index.js',
          content: 'console.log("hello from node")',
        },
      ],
    });
  });
});

describe('R language configuration', () => {
  it('resolves R aliases', () => {
    for (const alias of ['r', 'R', 'rscript', 'Rscript', 'rstats']) {
      expect(resolveLanguage(alias)).toBe(Languages.r);
    }
  });

  it('maps R requests to the r sandbox runtime', () => {
    expect(languageConfig[Languages.r]).toEqual({
      language: 'r',
      version: '4.5.2',
      fileName: 'script.R',
    });
  });

  it('aligns the package installer and Helm with the selected R runtime', () => {
    const root = path.resolve(__dirname, '../..');
    const version = languageConfig[Languages.r]!.version;
    expect(readFileSync(path.join(root, 'docker/package-init.sh'), 'utf8'))
      .toContain(`R_VERSION="\${R_VERSION:-${version}}"`);
    expect(readFileSync(path.join(root, 'helm/codeapi/values.yaml'), 'utf8'))
      .toContain(`rVersion: "${version}"`);
    // The image build must bake the same R the service asks the sandbox for;
    // a mismatch resolves no runtime and fails every R job at dispatch.
    expect(readFileSync(path.join(root, 'api/Dockerfile'), 'utf8'))
      .toContain(`ENV R_VERSION=${version}`);
  });

  it('keeps /usr/bin/which resolvable inside the jail for R', () => {
    // base::Sys.which() has "/usr/bin/which" compiled in at R's configure
    // time, so no PATH entry substitutes for it. Debian points that path
    // through /etc/alternatives, which the jail does not mount, so the link
    // has to be collapsed into /usr at image build time. Without it utils'
    // .onLoad fails, stats follows, and every R job dies with the unhelpful
    // "Function not implemented".
    const root = path.resolve(__dirname, '../..');
    const dockerfile = readFileSync(path.join(root, 'api/Dockerfile'), 'utf8');
    expect(dockerfile).toContain('ln -sf /usr/bin/which.debianutils /usr/bin/which');
  });

  it('keeps the R package manifest readable by package-init.sh', () => {
    const root = path.resolve(__dirname, '../..');
    const manifest = readFileSync(path.join(root, 'r-packages.txt'), 'utf8');
    const lines = manifest.split('\n');

    // package-init.sh stops at this exact header for R_PACKAGE_SET=core, so
    // the tier split has to survive edits to the manifest.
    const extendedAt = lines.findIndex(line => /^\s*#\s*---\s*extended/.test(line));
    expect(extendedAt).toBeGreaterThan(0);

    const isPackage = (line: string) => line.trim() !== '' && !line.trim().startsWith('#');
    const core = lines.slice(0, extendedAt).filter(isPackage);
    const extended = lines.slice(extendedAt + 1).filter(isPackage);

    expect(core.length).toBeGreaterThan(0);
    expect(extended.length).toBeGreaterThan(0);
    // CRAN package names, not name@version: the snapshot date pins versions.
    for (const name of [...core, ...extended]) {
      expect(name.trim()).toMatch(/^[A-Za-z][A-Za-z0-9._]*$/);
    }
    // A package listed twice wastes build time and usually hides a typo.
    const all = [...core, ...extended].map(name => name.trim());
    expect(new Set(all).size).toBe(all.length);
  });

  it('creates a valid R execution payload', () => {
    const req = {
      body: {
        lang: 'r',
        code: 'cat(mean(c(1, 2, 3)), "\\n")',
        args: [],
        files: [],
      },
    } as unknown as AuthenticatedRequest;

    const payload = createPayload({
      req,
      isPyPlot: false,
      session_id: 'session-r',
    });

    expect(payload).toMatchObject({
      language: 'r',
      version: '4.5.2',
      session_id: 'session-r',
      files: [
        {
          name: 'script.R',
          content: 'cat(mean(c(1, 2, 3)), "\\n")',
        },
      ],
    });
  });

  it('leaves R out of the programmatic tool-calling surface', () => {
    // PTC generates a Python or bash preamble only. Adding R to Languages
    // must not make it reachable there, or R code would be prefixed with a
    // Python preamble and fail at parse.
    expect(resolveLanguage('r')).not.toBe(Languages.py);
    expect(resolveLanguage('r')).not.toBe(Languages.bash);
  });
});

describe('runtime version configuration', () => {
  it('maps Python requests to Python 3.14.4', () => {
    expect(languageConfig[Languages.py]).toMatchObject({
      language: 'python',
      version: '3.14.4',
      fileName: 'main.py',
    });
  });

  it('maps Bun JavaScript and TypeScript requests to Bun 1.4.4', () => {
    expect(languageConfig[Languages.js]).toMatchObject({
      language: 'bun-js',
      version: '1.4.4',
      fileName: 'index.js',
    });
    expect(languageConfig[Languages.ts]).toMatchObject({
      language: 'bun-ts',
      version: '1.4.4',
      fileName: 'main.ts',
    });
  });
});

describe('egress grant TTL configuration', () => {
  it('defaults to job timeout plus grace without a fixed 30 minute cap', () => {
    expect(resolveEgressGrantTtlSeconds(undefined, 45 * 60 * 1000)).toBe(55 * 60);
  });

  it('honors explicit positive TTL overrides', () => {
    expect(resolveEgressGrantTtlSeconds('7200', 300000)).toBe(7200);
    expect(resolveEgressGrantTtlSeconds('1.2', 300000)).toBe(2);
  });

  it('falls back to the job-based default for invalid overrides', () => {
    expect(resolveEgressGrantTtlSeconds('0', 300000)).toBe(900);
    expect(resolveEgressGrantTtlSeconds('-1', 300000)).toBe(900);
    expect(resolveEgressGrantTtlSeconds('not-a-number', 300000)).toBe(900);
  });
});

describe('job deadline accounting', () => {
  it('never extends the producer deadline when worker configuration differs', () => {
    expect(jobDeadlineAtMs(1_000, 300_000, 50_000, 91_000)).toBe(91_000);
    expect(jobDeadlineAtMs(1_000, 30_000, 50_000, 91_000)).toBe(31_000);
    expect(jobDeadlineAtMs(1_000, 300_000, 50_000, Number.NaN)).toBe(0);
  });
  it('counts time spent waiting in BullMQ against JOB_TIMEOUT', () => {
    expect(jobDeadlineAtMs(1_000, 300_000, 50_000)).toBe(301_000);
  });

  it('falls back to worker start only when enqueue time is unavailable', () => {
    expect(jobDeadlineAtMs(undefined, 300_000, 50_000)).toBe(350_000);
    expect(jobDeadlineAtMs(Number.NaN, 300_000, 50_000)).toBe(350_000);
  });

  it('gives the worker bounded cleanup time after the execution deadline', () => {
    expect(jobCompletionWaitTimeoutMs(300_000, 60_000, 5_000)).toBe(370_000);
  });
});

describe('Lambda MicroVM numeric configuration', () => {
  it('uses defaults only for absent or blank values and preserves suspend=0', () => {
    expect(resolveLambdaMicrovmNumericConfig({})).toMatchObject({
      LAMBDA_MICROVM_PORT: 8080,
      LAMBDA_MICROVM_MAX_DURATION_SECONDS: 28_800,
      LAMBDA_MICROVM_IDLE_SECONDS: 1_800,
      LAMBDA_MICROVM_SUSPEND_SECONDS: 1_800,
      LAMBDA_MICROVM_AUTH_TOKEN_TTL_SECONDS: 300,
      LAMBDA_MICROVM_LAUNCH_TIMEOUT_MS: 60_000,
      LAMBDA_MICROVM_HEALTH_TIMEOUT_MS: 5_000,
      LAMBDA_MICROVM_LAUNCH_TPS: 4,
      LAMBDA_MICROVM_TOKEN_TPS: 8,
    });
    expect(resolveLambdaMicrovmNumericConfig({
      LAMBDA_MICROVM_SUSPEND_SECONDS: '0',
      LAMBDA_MICROVM_PORT: ' ',
    }).LAMBDA_MICROVM_SUSPEND_SECONDS).toBe(0);
  });

  it('accepts the supported boundary values', () => {
    const numeric = resolveLambdaMicrovmNumericConfig({
      LAMBDA_MICROVM_PORT: '1',
      LAMBDA_MICROVM_MAX_DURATION_SECONDS: '28800',
      LAMBDA_MICROVM_IDLE_SECONDS: '60',
      LAMBDA_MICROVM_SUSPEND_SECONDS: '0',
      LAMBDA_MICROVM_AUTH_TOKEN_TTL_SECONDS: '1',
      LAMBDA_MICROVM_LAUNCH_TIMEOUT_MS: '1',
      LAMBDA_MICROVM_HEALTH_TIMEOUT_MS: '1',
      LAMBDA_MICROVM_LAUNCH_TPS: '1',
      LAMBDA_MICROVM_TOKEN_TPS: '1',
    });
    expect(lambdaMicrovmNumericConfigError(numeric)).toBeUndefined();
  });

  it('rejects non-integers and values outside the supported ranges', () => {
    const cases: Array<[string, string, string]> = [
      ['LAMBDA_MICROVM_PORT', '0', 'between 1 and 65535'],
      ['LAMBDA_MICROVM_PORT', '65536', 'between 1 and 65535'],
      ['LAMBDA_MICROVM_MAX_DURATION_SECONDS', '28801', 'between 1 and 28800'],
      ['LAMBDA_MICROVM_IDLE_SECONDS', '59', 'between 60 and 28800'],
      ['LAMBDA_MICROVM_SUSPEND_SECONDS', '-1', 'between 0 and 28800'],
      ['LAMBDA_MICROVM_AUTH_TOKEN_TTL_SECONDS', '901', 'between 1 and 900'],
      ['LAMBDA_MICROVM_LAUNCH_TIMEOUT_MS', '0', 'at least 1'],
      ['LAMBDA_MICROVM_HEALTH_TIMEOUT_MS', 'NaN', 'at least 1'],
      ['LAMBDA_MICROVM_LAUNCH_TPS', '1.5', 'at least 1'],
      ['LAMBDA_MICROVM_TOKEN_TPS', '-1', 'at least 1'],
    ];

    for (const [name, value, expected] of cases) {
      const numeric = resolveLambdaMicrovmNumericConfig({ [name]: value });
      expect(lambdaMicrovmNumericConfigError(numeric)).toContain(name);
      expect(lambdaMicrovmNumericConfigError(numeric)).toContain(expected);
    }
  });
});
