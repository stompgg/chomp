/**
 * MonMetadata-equivalent for the arena, built from chomp's drool CSVs. Provides the fields the arena
 * analysis reads: `.id`, `.name`, `.stats` (base stats), and `.moves[i].name` per slot (the move NAMES,
 * indexed to line up with the engine's stored move slots via `monMoveSlots`).
 */
import { loadRoster } from '../util/csv-load';
import { monMoveSlots } from '../arena/team';

export interface MonMeta {
  id: number;
  name: string;
  stats: {
    hp: number;
    attack: number;
    defense: number;
    specialAttack: number;
    specialDefense: number;
    speed: number;
  };
  moves: { name: string }[];
}

const roster = loadRoster();

export const MonMetadata: Record<number, MonMeta> = {};
for (const mon of roster.mons) {
  MonMetadata[mon.id] = {
    id: mon.id,
    name: mon.name,
    stats: {
      hp: mon.hp,
      attack: mon.attack,
      defense: mon.defense,
      specialAttack: mon.specialAttack,
      specialDefense: mon.specialDefense,
      speed: mon.speed,
    },
    moves: monMoveSlots(roster, mon).map((s) => ({ name: s.name })),
  };
}
