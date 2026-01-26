/**
 * Shared test utilities for the transpiler test suite.
 *
 * Provides a simple test framework without vitest:
 * - test(): Register a test case
 * - expect(): Jest-like assertion helper
 * - runTests(): Execute all registered tests
 */

import { strict as assert } from 'node:assert';

// Test registry
const tests: Array<{ name: string; fn: () => void | Promise<void> }> = [];
let passed = 0;
let failed = 0;

/**
 * Register a test case.
 */
export function test(name: string, fn: () => void | Promise<void>) {
  tests.push({ name, fn });
}

/**
 * Jest-like assertion helper.
 */
export function expect<T>(actual: T) {
  return {
    toBe(expected: T) {
      assert.strictEqual(actual, expected);
    },
    toEqual(expected: T) {
      assert.deepStrictEqual(actual, expected);
    },
    not: {
      toBe(expected: T) {
        assert.notStrictEqual(actual, expected);
      },
    },
    toBeGreaterThan(expected: number | bigint) {
      assert.ok(actual > expected, `Expected ${actual} > ${expected}`);
    },
    toBeLessThan(expected: number | bigint) {
      assert.ok(actual < expected, `Expected ${actual} < ${expected}`);
    },
    toBeGreaterThanOrEqual(expected: number | bigint) {
      assert.ok(actual >= expected, `Expected ${actual} >= ${expected}`);
    },
    toBeLessThanOrEqual(expected: number | bigint) {
      assert.ok(actual <= expected, `Expected ${actual} <= ${expected}`);
    },
    toBeTruthy() {
      assert.ok(actual);
    },
    toBeFalsy() {
      assert.ok(!actual);
    },
  };
}

/**
 * Run all registered tests and exit with appropriate code.
 * @param label Optional label for the test suite (defaults to "tests")
 */
export async function runTests(label: string = 'tests') {
  console.log(`\nRunning ${tests.length} ${label}...\n`);

  for (const { name, fn } of tests) {
    try {
      await fn();
      passed++;
      console.log(`  ✓ ${name}`);
    } catch (err) {
      failed++;
      console.log(`  ✗ ${name}`);
      console.log(`    ${(err as Error).message}`);
      if ((err as Error).stack) {
        console.log(`    ${(err as Error).stack?.split('\n').slice(1, 4).join('\n    ')}`);
      }
    }
  }

  console.log(`\n${passed} passed, ${failed} failed\n`);
  process.exit(failed > 0 ? 1 : 0);
}

/**
 * Reset the test registry (useful for programmatic test running).
 */
export function resetTests() {
  tests.length = 0;
  passed = 0;
  failed = 0;
}
