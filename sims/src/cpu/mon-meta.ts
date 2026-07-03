/**
 * MonMetadata-equivalent for the arena, built from chomp's drool CSVs. Provides the fields the arena
 * analysis reads: `.id`, `.name`, `.stats` (base stats), and `.moves[i].name` — the mon's full move
 * catalog (learnset order) via `monCatalog`. The arena maps each played battle slot back to a catalog
 * entry through the draft's `equip`, so `.moves` labels every move a mon could field, not just its
 * default four.
 */
import { loadRoster } from '../util/csv-load';
import { monCatalog } from '../arena/team';

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
    moves: monCatalog(roster, mon).map((s) => ({ name: s.name })),
  };
}
