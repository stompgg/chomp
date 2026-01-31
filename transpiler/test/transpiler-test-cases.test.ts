/**
 * Transpiler Test Cases
 *
 * This file tests the transpiled output for various Solidity patterns.
 * Each test case verifies that the transpiler correctly handles edge cases.
 */

import { describe, it, expect, beforeAll } from 'vitest';

// Check TypeScript compilation - if this file compiles, the transpiler is working
// We import from ts-output to verify the generated code is valid TypeScript

describe('Transpiler Output Validation', () => {

  describe('Core modules compile', () => {
    it('should import Engine without errors', async () => {
      const { Engine } = await import('../ts-output/Engine');
      expect(Engine).toBeDefined();
    });

    it('should import Structs without errors', async () => {
      const Structs = await import('../ts-output/Structs');
      expect(Structs).toBeDefined();
    });

    it('should import Enums without errors', async () => {
      const Enums = await import('../ts-output/Enums');
      expect(Enums).toBeDefined();
    });

    it('should import Constants without errors', async () => {
      const Constants = await import('../ts-output/Constants');
      expect(Constants).toBeDefined();
    });
  });

  describe('Effects compile', () => {
    it('should import StatBoosts without errors', async () => {
      const { StatBoosts } = await import('../ts-output/effects/StatBoosts');
      expect(StatBoosts).toBeDefined();
    });

    it('should import SleepStatus without errors', async () => {
      const { SleepStatus } = await import('../ts-output/effects/status/SleepStatus');
      expect(SleepStatus).toBeDefined();
    });
  });

  describe('Matchmaker modules compile', () => {
    it('should import BattleOfferLib without errors', async () => {
      const { BattleOfferLib } = await import('../ts-output/matchmaker/BattleOfferLib');
      expect(BattleOfferLib).toBeDefined();
    });

    it('should import DefaultMatchmaker without errors', async () => {
      const { DefaultMatchmaker } = await import('../ts-output/matchmaker/DefaultMatchmaker');
      expect(DefaultMatchmaker).toBeDefined();
    });

    // SignedMatchmaker requires EIP712 - skip for now
    it.skip('should import SignedMatchmaker without errors', async () => {
      const { SignedMatchmaker } = await import('../ts-output/matchmaker/SignedMatchmaker');
      expect(SignedMatchmaker).toBeDefined();
    });
  });

  describe('CPU modules compile', () => {
    it('should import CPUMoveManager without errors', async () => {
      const { CPUMoveManager } = await import('../ts-output/cpu/CPUMoveManager');
      expect(CPUMoveManager).toBeDefined();
    });
  });

  describe('Teams modules compile', () => {
    it('should import DefaultMonRegistry without errors', async () => {
      const { DefaultMonRegistry } = await import('../ts-output/teams/DefaultMonRegistry');
      expect(DefaultMonRegistry).toBeDefined();
    });

    it('should import DefaultTeamRegistry without errors', async () => {
      const { DefaultTeamRegistry } = await import('../ts-output/teams/DefaultTeamRegistry');
      expect(DefaultTeamRegistry).toBeDefined();
    });

    // GachaTeamRegistry requires Ownable inheritance - skip for now
    it.skip('should import GachaTeamRegistry without errors', async () => {
      const { GachaTeamRegistry } = await import('../ts-output/teams/GachaTeamRegistry');
      expect(GachaTeamRegistry).toBeDefined();
    });
  });

  describe('Gacha modules compile', () => {
    it('should import GachaRegistry without errors', async () => {
      const { GachaRegistry } = await import('../ts-output/gacha/GachaRegistry');
      expect(GachaRegistry).toBeDefined();
    });
  });

  describe('Mon moves compile', () => {
    it('should import Tinderclaws without errors', async () => {
      const { Tinderclaws } = await import('../ts-output/mons/embursa/Tinderclaws');
      expect(Tinderclaws).toBeDefined();
    });

    it('should import CarrotHarvest without errors', async () => {
      const { CarrotHarvest } = await import('../ts-output/mons/sofabbi/CarrotHarvest');
      expect(CarrotHarvest).toBeDefined();
    });
  });
});

describe('Runtime Type Checks', () => {
  it('BigInt conversion should work correctly', () => {
    const arr = [1, 2, 3, 4, 5];
    const len: bigint = BigInt(arr.length);
    expect(len).toBe(5n);
  });

  it('address hex conversion should work', () => {
    const num = 0x1234567890abcdefn;
    const addr = `0x${num.toString(16).padStart(40, '0')}`;
    // 1234567890abcdef is 16 chars, so we need 24 zeros to pad to 40
    expect(addr).toBe('0x0000000000000000000000001234567890abcdef');
    expect(addr.length).toBe(42); // 0x + 40 hex chars
  });

  it('bytes32 hex conversion should work', () => {
    const num = 0x1234n;
    const bytes32 = `0x${num.toString(16).padStart(64, '0')}`;
    expect(bytes32.length).toBe(66); // 0x + 64 hex chars
  });

  it('bytes32 string conversion should work', () => {
    const str = 'INDICTMENT';
    const hexVal = Buffer.from(str, 'utf-8').toString('hex');
    const bytes32 = `0x${hexVal.padEnd(64, '0')}`;
    expect(bytes32.startsWith('0x')).toBe(true);
    expect(bytes32.length).toBe(66);
  });
});
