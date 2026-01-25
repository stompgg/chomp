#!/usr/bin/env npx tsx
/**
 * Move Metadata Extractor
 *
 * Parses Solidity move files and extracts metadata from:
 * 1. StandardAttack-based moves (ATTACK_PARAMS in constructor)
 * 2. IMoveSet direct implementations (values from getter methods)
 *
 * Usage: npx tsx extract-move-metadata.ts [--output ./generated/move-metadata.json]
 */

import { readFileSync, writeFileSync, readdirSync, statSync } from 'fs';
import { join, relative, basename } from 'path';

interface RawMoveMetadata {
  contractName: string;
  filePath: string;
  inheritsFrom: string;
  name: string;
  basePower: string | number;
  staminaCost: string | number;
  accuracy: string | number;
  priority: string | number;
  moveType: string;
  moveClass: string;
  critRate: string | number;
  volatility: string | number;
  effectAccuracy: string | number;
  effect: string | null;
  extraDataType: string;
  customConstants?: Record<string, string | number>;
  customBehavior?: string;
}

const SRC_DIR = join(__dirname, '../../src');
const MONS_DIR = join(SRC_DIR, 'mons');

/**
 * Recursively find all .sol files in a directory
 */
function findSolidityFiles(dir: string): string[] {
  const results: string[] = [];
  const items = readdirSync(dir);

  for (const item of items) {
    const fullPath = join(dir, item);
    const stat = statSync(fullPath);

    if (stat.isDirectory()) {
      results.push(...findSolidityFiles(fullPath));
    } else if (item.endsWith('.sol') && !item.includes('Lib')) {
      results.push(fullPath);
    }
  }

  return results;
}

/**
 * Parse a single ATTACK_PARAMS struct literal from source
 */
function parseAttackParams(content: string): Partial<RawMoveMetadata> | null {
  // Match ATTACK_PARAMS({ ... })
  const paramsMatch = content.match(/ATTACK_PARAMS\s*\(\s*\{([\s\S]*?)\}\s*\)/);
  if (!paramsMatch) return null;

  const paramsBlock = paramsMatch[1];
  const result: Partial<RawMoveMetadata> = {};

  // Parse each field
  const fieldPatterns: Record<string, keyof RawMoveMetadata> = {
    'NAME': 'name',
    'BASE_POWER': 'basePower',
    'STAMINA_COST': 'staminaCost',
    'ACCURACY': 'accuracy',
    'PRIORITY': 'priority',
    'MOVE_TYPE': 'moveType',
    'MOVE_CLASS': 'moveClass',
    'CRIT_RATE': 'critRate',
    'VOLATILITY': 'volatility',
    'EFFECT_ACCURACY': 'effectAccuracy',
    'EFFECT': 'effect',
  };

  for (const [solidityField, metadataField] of Object.entries(fieldPatterns)) {
    // Match patterns like: NAME: "Bull Rush" or BASE_POWER: 120 or MOVE_TYPE: Type.Metal
    const regex = new RegExp(`${solidityField}\\s*:\\s*([^,}]+)`, 'i');
    const match = paramsBlock.match(regex);

    if (match) {
      let value: string | number = match[1].trim();

      // Handle string literals
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.slice(1, -1);
      }
      // Handle numeric literals
      else if (/^\d+$/.test(value)) {
        value = parseInt(value, 10);
      }
      // Handle Type.* and MoveClass.* enums
      else if (value.startsWith('Type.')) {
        value = value.replace('Type.', '');
      }
      else if (value.startsWith('MoveClass.')) {
        value = value.replace('MoveClass.', '');
      }
      // Handle IEffect(address(0)) as null
      else if (value.includes('address(0)')) {
        value = 'null';
      }
      // Keep constant references as strings (e.g., DEFAULT_PRIORITY)

      (result as Record<string, unknown>)[metadataField] = value === 'null' ? null : value;
    }
  }

  return result;
}

/**
 * Extract custom constants from a contract (public constant declarations)
 */
function extractCustomConstants(content: string): Record<string, string | number> {
  const constants: Record<string, string | number> = {};

  // Match patterns like: uint256 public constant SELF_DAMAGE_PERCENT = 20;
  const constantRegex = /(?:uint\d*|int\d*)\s+public\s+constant\s+(\w+)\s*=\s*(\d+)/g;
  let match;

  while ((match = constantRegex.exec(content)) !== null) {
    constants[match[1]] = parseInt(match[2], 10);
  }

  return constants;
}

/**
 * Extract extraDataType override from a contract
 */
function extractExtraDataType(content: string): string {
  // Match: function extraDataType() ... returns (ExtraDataType) { return ExtraDataType.X; }
  const match = content.match(/function\s+extraDataType\s*\([^)]*\)[^{]*\{[^}]*return\s+ExtraDataType\.(\w+)/);
  return match ? match[1] : 'None';
}

/**
 * Check if contract has custom move() override
 */
function hasCustomMoveBehavior(content: string): boolean {
  // Look for move function override with actual implementation
  const moveMatch = content.match(/function\s+move\s*\([^)]*\)[^{]*override[^{]*\{([\s\S]*?)\n\s*\}/);
  if (!moveMatch) return false;

  const body = moveMatch[1];
  // If it just calls _move() and nothing else, it's not custom
  const hasOnlyMoveCall = /^\s*_move\s*\([^)]*\)\s*;?\s*$/.test(body.trim());
  return !hasOnlyMoveCall;
}

/**
 * Describe custom behavior based on contract analysis
 */
function describeCustomBehavior(content: string, contractName: string): string | undefined {
  const behaviors: string[] = [];

  // Check for self-damage
  if (content.includes('SELF_DAMAGE') || content.includes('selfDamage')) {
    behaviors.push('self-damage');
  }

  // Check for switch
  if (content.includes('switchActiveMon')) {
    behaviors.push('force-switch');
  }

  // Check for stat modification
  if (content.includes('updateMonState')) {
    behaviors.push('stat-modification');
  }

  // Check for effect application
  if (content.includes('addEffect')) {
    behaviors.push('applies-effect');
  }

  // Check for healing
  if (content.includes('healDamage') || content.includes('HEAL')) {
    behaviors.push('healing');
  }

  // Check for random base power
  if (content.includes('rng') && content.includes('basePower')) {
    behaviors.push('random-power');
  }

  return behaviors.length > 0 ? behaviors.join(', ') : undefined;
}

/**
 * Parse a move contract that directly implements IMoveSet
 */
function parseIMoveSetImplementation(content: string): Partial<RawMoveMetadata> | null {
  const result: Partial<RawMoveMetadata> = {};

  // Extract name from name() function
  const nameMatch = content.match(/function\s+name\s*\([^)]*\)[^{]*\{[^}]*return\s*"([^"]+)"/);
  if (nameMatch) {
    result.name = nameMatch[1];
  }

  // Extract stamina
  const staminaMatch = content.match(/function\s+stamina\s*\([^)]*\)[^{]*\{[^}]*return\s+(\d+|DEFAULT_STAMINA)/);
  if (staminaMatch) {
    result.staminaCost = /^\d+$/.test(staminaMatch[1])
      ? parseInt(staminaMatch[1], 10)
      : staminaMatch[1];
  }

  // Extract priority
  const priorityMatch = content.match(/function\s+priority\s*\([^)]*\)[^{]*\{[^}]*return\s+(\d+|DEFAULT_PRIORITY)/);
  if (priorityMatch) {
    result.priority = /^\d+$/.test(priorityMatch[1])
      ? parseInt(priorityMatch[1], 10)
      : priorityMatch[1];
  }

  // Extract moveType
  const typeMatch = content.match(/function\s+moveType\s*\([^)]*\)[^{]*\{[^}]*return\s+Type\.(\w+)/);
  if (typeMatch) {
    result.moveType = typeMatch[1];
  }

  // Extract moveClass
  const classMatch = content.match(/function\s+moveClass\s*\([^)]*\)[^{]*\{[^}]*return\s+MoveClass\.(\w+)/);
  if (classMatch) {
    result.moveClass = classMatch[1];
  }

  // Check if any values were found
  if (Object.keys(result).length === 0) return null;

  // Set defaults for missing values (indicates special move logic)
  result.basePower = result.basePower ?? 'dynamic';
  result.accuracy = result.accuracy ?? 'DEFAULT_ACCURACY';
  result.critRate = result.critRate ?? 'DEFAULT_CRIT_RATE';
  result.volatility = result.volatility ?? 'DEFAULT_VOL';
  result.effectAccuracy = result.effectAccuracy ?? 0;
  result.effect = null;

  return result;
}

/**
 * Extract contract name and inheritance from source
 */
function extractContractInfo(content: string): { name: string; inheritsFrom: string } | null {
  // Match: contract ContractName is Parent1, Parent2 {
  const match = content.match(/contract\s+(\w+)\s+is\s+([^{]+)\s*\{/);
  if (!match) return null;

  const name = match[1];
  const inheritsList = match[2].split(',').map(s => s.trim());

  // Determine primary parent
  let inheritsFrom = 'unknown';
  if (inheritsList.includes('StandardAttack')) {
    inheritsFrom = 'StandardAttack';
  } else if (inheritsList.includes('IMoveSet')) {
    inheritsFrom = 'IMoveSet';
  } else if (inheritsList.some(i => i.includes('Effect') || i.includes('Ability'))) {
    inheritsFrom = 'Effect/Ability';
  }

  return { name, inheritsFrom };
}

/**
 * Parse a single Solidity file and extract move metadata
 */
function parseMoveFile(filePath: string): RawMoveMetadata | null {
  const content = readFileSync(filePath, 'utf-8');
  const relativePath = relative(SRC_DIR, filePath);

  const contractInfo = extractContractInfo(content);
  if (!contractInfo) return null;

  // Skip non-move contracts
  if (contractInfo.inheritsFrom === 'Effect/Ability') {
    return null;
  }

  let metadata: Partial<RawMoveMetadata>;

  if (contractInfo.inheritsFrom === 'StandardAttack') {
    const params = parseAttackParams(content);
    if (!params) return null;
    metadata = params;
  } else if (contractInfo.inheritsFrom === 'IMoveSet') {
    const params = parseIMoveSetImplementation(content);
    if (!params) return null;
    metadata = params;
  } else {
    return null;
  }

  // Extract additional info
  const customConstants = extractCustomConstants(content);
  const extraDataType = extractExtraDataType(content);
  const hasCustomBehavior = hasCustomMoveBehavior(content);
  const customBehavior = hasCustomBehavior
    ? describeCustomBehavior(content, contractInfo.name)
    : undefined;

  return {
    contractName: contractInfo.name,
    filePath: relativePath,
    inheritsFrom: contractInfo.inheritsFrom,
    name: metadata.name ?? contractInfo.name,
    basePower: metadata.basePower ?? 0,
    staminaCost: metadata.staminaCost ?? 'DEFAULT_STAMINA',
    accuracy: metadata.accuracy ?? 'DEFAULT_ACCURACY',
    priority: metadata.priority ?? 'DEFAULT_PRIORITY',
    moveType: metadata.moveType ?? 'None',
    moveClass: metadata.moveClass ?? 'Other',
    critRate: metadata.critRate ?? 'DEFAULT_CRIT_RATE',
    volatility: metadata.volatility ?? 'DEFAULT_VOL',
    effectAccuracy: metadata.effectAccuracy ?? 0,
    effect: metadata.effect ?? null,
    extraDataType,
    ...(Object.keys(customConstants).length > 0 && { customConstants }),
    ...(customBehavior && { customBehavior }),
  };
}

/**
 * Main extraction function
 */
function extractAllMoveMetadata(): RawMoveMetadata[] {
  const moveFiles = findSolidityFiles(MONS_DIR);
  const metadata: RawMoveMetadata[] = [];

  for (const filePath of moveFiles) {
    try {
      const moveMetadata = parseMoveFile(filePath);
      if (moveMetadata) {
        metadata.push(moveMetadata);
      }
    } catch (error) {
      console.error(`Error parsing ${filePath}:`, error);
    }
  }

  // Sort by contract name
  metadata.sort((a, b) => a.contractName.localeCompare(b.contractName));

  return metadata;
}

/**
 * Group moves by mon (based on file path)
 */
function groupByMon(moves: RawMoveMetadata[]): Record<string, RawMoveMetadata[]> {
  const groups: Record<string, RawMoveMetadata[]> = {};

  for (const move of moves) {
    // Extract mon name from path (e.g., "mons/aurox/BullRush.sol" -> "aurox")
    const pathParts = move.filePath.split('/');
    const monIndex = pathParts.indexOf('mons');
    const monName = monIndex >= 0 && pathParts[monIndex + 1]
      ? pathParts[monIndex + 1]
      : 'unknown';

    if (!groups[monName]) {
      groups[monName] = [];
    }
    groups[monName].push(move);
  }

  return groups;
}

// Main execution
const args = process.argv.slice(2);
const outputIndex = args.indexOf('--output');
const outputPath = outputIndex >= 0 && args[outputIndex + 1]
  ? args[outputIndex + 1]
  : join(__dirname, '../generated/move-metadata.json');

console.log('Extracting move metadata from Solidity files...');
console.log(`Source directory: ${MONS_DIR}`);

const allMoves = extractAllMoveMetadata();
const groupedMoves = groupByMon(allMoves);

const output = {
  generatedAt: new Date().toISOString(),
  totalMoves: allMoves.length,
  movesByMon: groupedMoves,
  allMoves,
};

writeFileSync(outputPath, JSON.stringify(output, null, 2));

console.log(`\nExtracted ${allMoves.length} moves:`);
for (const [mon, moves] of Object.entries(groupedMoves)) {
  console.log(`  ${mon}: ${moves.map(m => m.contractName).join(', ')}`);
}
console.log(`\nOutput written to: ${outputPath}`);
