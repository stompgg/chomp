import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { MonRow, Roster } from '../util/csv-load';
import type { BestMoveCell, MonOpponentList, OutspeedMatrix, StatRanks, StaticMetrics, TypeCoverage } from '../metrics/static/types';
import type { DamageDistribution } from '../metrics/engine/damage-hist';
import type { Flag, Report } from './types';

const REPORT_DIR = join(import.meta.dir, '..', '..', 'reports');
const SPRITE_REL = '../../drool/imgs';

function esc(s: unknown): string {
  return String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);
}

function num(n: number, digits = 1): string {
  if (!Number.isFinite(n)) return '∞';
  return n.toFixed(digits);
}

// Subtle type tinting — paired bg (translucent) + fg so badges are readable on the dark panel.
const TYPE_COLORS: Record<string, { bg: string; fg: string }> = {
  Fire:       { bg: 'rgba(231,76,60,0.18)',  fg: '#ff8a65' },
  Liquid:     { bg: 'rgba(52,152,219,0.18)', fg: '#7fc7ff' },
  Earth:      { bg: 'rgba(160,82,45,0.22)',  fg: '#d2a878' },
  Air:        { bg: 'rgba(189,195,199,0.16)', fg: '#dfe6e9' },
  Lightning:  { bg: 'rgba(241,196,15,0.20)', fg: '#ffe066' },
  Ice:        { bg: 'rgba(116,185,255,0.18)', fg: '#a3d8ff' },
  Nature:     { bg: 'rgba(39,174,96,0.18)',  fg: '#7fdb8e' },
  Metal:      { bg: 'rgba(127,140,141,0.20)', fg: '#cbd3d6' },
  Mythic:     { bg: 'rgba(155,89,182,0.20)', fg: '#c39bd3' },
  Yin:        { bg: 'rgba(44,62,80,0.32)',   fg: '#9bb6d1' },
  Yang:       { bg: 'rgba(247,220,111,0.20)', fg: '#f9e79f' },
  Math:       { bg: 'rgba(232,67,147,0.20)', fg: '#fd79a8' },
  Cyber:      { bg: 'rgba(0,206,201,0.18)',  fg: '#7eedea' },
  Wild:       { bg: 'rgba(205,133,63,0.20)', fg: '#e8b97c' },
  Cosmic:     { bg: 'rgba(108,92,231,0.22)', fg: '#b8a8ff' },
  None:       { bg: 'rgba(255,255,255,0.06)', fg: '#b0b0b0' },
};

function typeBadge(t: string | undefined | null): string {
  if (!t || t === 'NA') return '';
  const c = TYPE_COLORS[t] ?? { bg: 'rgba(255,255,255,0.06)', fg: 'var(--text)' };
  return `<span class="type-badge" style="background:${c.bg};color:${c.fg}">${esc(t)}</span>`;
}

function typeFg(t: string | null | undefined): string {
  if (!t || t === 'NA') return 'inherit';
  return TYPE_COLORS[t]?.fg ?? 'inherit';
}

function monMini(name: string): string {
  const src = `${SPRITE_REL}/${name.toLowerCase()}_mini.gif`;
  return `<img class="mini-sprite" src="${esc(src)}" alt="" onerror="this.style.display='none'">`;
}

const SUGGESTION_BREAK_THRESHOLD = 60;

function multClass(m: number): string {
  if (m > 1) return 'mult-super';
  if (m < 1 && m > 0) return 'mult-resist';
  if (m === 0) return 'mult-immune';
  return 'mult-neutral';
}

function damageHoverHtml(c: BestMoveCell): string {
  const htko = c.htko === Infinity ? '∞' : c.htko;
  return `<div class="hover-card">
    <div class="hover-head"><strong>${esc(c.attacker)}</strong> <span class="hover-arrow">→</span> <strong>${esc(c.defender)}</strong></div>
    <div class="hover-move">${esc(c.moveName ?? '—')} <span class="hover-meta">${esc(c.moveClass ?? '')}</span> ${typeBadge(c.moveType)}</div>
    <div class="hover-stats">
      <span><span class="hover-k">dmg</span> <span class="hover-v">${num(c.damage, 0)}</span></span>
      <span><span class="hover-k">%HP</span> <span class="hover-v">${num(c.percentHp, 1)}%</span></span>
      <span><span class="hover-k">HtKO</span> <span class="hover-v">${htko}</span></span>
      <span class="hover-mult ${multClass(c.typeMult)}"><span class="hover-k">type</span> <span class="hover-v">×${c.typeMult}</span></span>
    </div>
  </div>`;
}

function damageCell(c: BestMoveCell): string {
  if (!c.moveName) return `<td class="cell empty"></td>`;
  const pct = c.percentHp;
  const r = Math.min(255, Math.round(255 * Math.min(1, pct / 100)));
  const g = Math.max(60, 200 - Math.round(140 * Math.min(1, pct / 100)));
  const bg = `rgb(${r},${g},80)`;
  const fg = pct > 60 ? '#fff' : '#111';
  const htko = c.htko === Infinity ? '∞' : c.htko;
  const hover = esc(damageHoverHtml(c));
  return `<td class="cell hoverable" style="background:${bg};color:${fg}" data-hover-html="${hover}">${num(pct, 0)}<span class="htko">${htko}</span></td>`;
}

function flagSection(flags: Flag[]): string {
  if (flags.length === 0) {
    return `<section><h2>Flags</h2><p class="muted">No anomalies tripped.</p></section>`;
  }
  const counts = flags.reduce<Record<string, number>>((acc, f) => ({ ...acc, [f.severity]: (acc[f.severity] ?? 0) + 1 }), {});
  const rows = flags
    .map((f) => {
      const parts = f.suggestion.split('\n');
      const isList = parts.length > 1;
      const long = isList || f.suggestion.length > SUGGESTION_BREAK_THRESHOLD;
      if (long) {
        const body = isList
          ? `<ul class="sg-list">${parts.map((p) => `<li>${esc(p)}</li>`).join('')}</ul>`
          : `<span class="sg-arrow">↳</span> ${esc(f.suggestion)}`;
        return `
        <tr class="sev-${f.severity} has-suggestion">
          <td class="sev">${f.severity}</td>
          <td class="rule">${esc(f.rule)}</td>
          <td>${esc(f.target)}</td>
          <td colspan="2">${esc(f.detail)}</td>
        </tr>
        <tr class="sev-${f.severity} suggestion-row">
          <td></td>
          <td colspan="4" class="suggestion">${body}</td>
        </tr>`;
      }
      return `
        <tr class="sev-${f.severity}">
          <td class="sev">${f.severity}</td>
          <td class="rule">${esc(f.rule)}</td>
          <td>${esc(f.target)}</td>
          <td>${esc(f.detail)}</td>
          <td class="suggestion">${esc(f.suggestion)}</td>
        </tr>`;
    })
    .join('');
  const summary = Object.entries(counts)
    .map(([k, v]) => `<span class="sev-${k} pill">${k}: ${v}</span>`)
    .join(' ');
  return `
    <section>
      <h2>Flags <small>${summary}</small></h2>
      <table class="flags">
        <thead><tr><th>Severity</th><th>Rule</th><th>Target</th><th>Detail</th><th>Suggestion</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </section>`;
}

function damageMatrixSection(report: Report): string {
  const m = report.static.damageMatrix;
  const head = m.defenders.map((d) => `<th>${esc(d)}</th>`).join('');
  const rows = m.attackers
    .map((att, i) => {
      const cells = m.cells[i].map((c, j) => (i === j ? `<td class="cell self"></td>` : damageCell(c))).join('');
      return `<tr><th class="row-label"><a href="#mon-${esc(att)}">${esc(att)}</a></th>${cells}</tr>`;
    })
    .join('');
  return `
    <section>
      <h2>Best-Move Damage Matrix <small>(static, avg roll · % defender HP · click row label to jump to mon)</small></h2>
      <p class="muted">Rows = attacker, columns = defender. Cell shows %HP and ⁰HKO count. Hover for move detail.</p>
      <div class="scroll">
        <table class="matrix">
          <thead><tr><th></th>${head}</tr></thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
    </section>`;
}

function tocSection(roster: Roster): string {
  const links = roster.mons
    .map((m) => `<a class="toc-link" href="#mon-${esc(m.name)}">${esc(m.name)}</a>`)
    .join(' · ');
  return `<section><h2>Per-Mon Cards</h2><p class="toc">${links}</p></section>`;
}

const STAT_KEYS: { key: keyof MonRow; label: string }[] = [
  { key: 'hp', label: 'HP' },
  { key: 'attack', label: 'Atk' },
  { key: 'defense', label: 'Def' },
  { key: 'specialAttack', label: 'SpA' },
  { key: 'specialDefense', label: 'SpD' },
  { key: 'speed', label: 'Spe' },
];

function statBar(value: number, rank: number, total: number, label: string): string {
  const pctBetterThan = ((total - rank) / (total - 1)) * 100;
  let badge = '';
  let cls = '';
  if (rank === 1 || rank === 2) {
    badge = '<span class="sb top">▲</span>';
    cls = 'top';
  } else if (rank === total || rank === total - 1) {
    badge = '<span class="sb bot">▼</span>';
    cls = 'bot';
  }
  return `
    <div class="stat-row ${cls}">
      <div class="stat-label">${label}</div>
      <div class="stat-value">${value}</div>
      <div class="stat-rank">#${rank}/${total}</div>
      <div class="stat-bar"><div class="stat-bar-fill" style="width:${pctBetterThan.toFixed(0)}%"></div></div>
      <div class="stat-pct">${pctBetterThan.toFixed(0)}%ile ${badge}</div>
    </div>`;
}

function monMovesTable(roster: Roster, mon: MonRow): string {
  const moves = roster.movesByMon.get(mon.name) ?? [];
  const ability = roster.abilityByMon.get(mon.name);
  const rows = moves
    .map((mv) => {
      const desc = mv.description?.trim();
      const hasDesc = Boolean(desc);
      const mainCls = hasDesc ? 'move-row has-desc' : 'move-row';
      const descRow = hasDesc
        ? `<tr class="move-desc-row"><td colspan="7" class="move-desc">${esc(desc)}</td></tr>`
        : '';
      return `
        <tr class="${mainCls}">
          <td style="color:${typeFg(mv.type)}">${esc(mv.name)}</td>
          <td>${esc(mv.cls)}</td>
          <td>${typeBadge(mv.type)}</td>
          <td class="num">${mv.power ?? '?'}</td>
          <td class="num">${mv.stamina ?? '?'}</td>
          <td class="num">${mv.accuracy ?? '?'}</td>
          <td class="num">${mv.priority > 0 ? `+${mv.priority}` : mv.priority}</td>
        </tr>${descRow}`;
    })
    .join('');
  const abilityRow = ability
    ? `<p class="ability"><strong>Ability:</strong> ${esc(ability.name)} <span class="muted">— ${esc(ability.effect)}</span></p>`
    : `<p class="ability muted">No ability listed</p>`;
  return `
    ${abilityRow}
    <table class="data tight">
      <thead><tr><th>Move</th><th>Class</th><th>Type</th><th>Power</th><th>Stam</th><th>Acc</th><th>Pri</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
}

interface MatchupRow {
  other: string;
  cell: BestMoveCell;
  engine: DamageDistribution | undefined;
}

type MatchupAxis = 'offense' | 'defense';

function engineCellHtml(c: BestMoveCell, eng: DamageDistribution | undefined): string {
  if (!eng) return '<span class="muted">—</span>';
  const ohkoCls = eng.ohkoProbability >= 0.5 ? 'critical' : '';
  const viaSuffix = eng.moveName !== c.moveName
    ? ` <span class="muted">(via ${esc(eng.moveName)})</span>`
    : '';
  return `<span class="num">mean ${eng.mean.toFixed(0)}%</span> · OHKO <span class="num ${ohkoCls}">${(eng.ohkoProbability * 100).toFixed(0)}%</span>${viaSuffix}`;
}

function htkoRowClass(htko: number): string {
  if (htko <= 1) return 'highlight';
  if (htko >= 5) return 'lowlight';
  return '';
}

function matchupTableRow(r: MatchupRow): string {
  const { other, cell: c, engine: eng } = r;
  const htkoText = c.htko === Infinity ? '∞' : c.htko;
  const htkoSort = c.htko === Infinity ? Number.MAX_SAFE_INTEGER : c.htko;
  const ohkoSort = eng ? eng.ohkoProbability : -1;
  return `
    <tr class="${htkoRowClass(c.htko)}">
      <td data-v="${esc(other)}">${monMini(other)}<a href="#mon-${esc(other)}">${esc(other)}</a></td>
      <td data-v="${esc(c.moveName ?? '')}" style="color:${typeFg(c.moveType)}">${esc(c.moveName ?? '—')}</td>
      <td class="num" data-v="${c.percentHp}">${num(c.percentHp, 0)}%</td>
      <td class="num" data-v="${htkoSort}">${htkoText}HKO</td>
      <td data-v="${ohkoSort}">${engineCellHtml(c, eng)}</td>
    </tr>`;
}

function matchupTableFor(
  monName: string,
  idx: number,
  axis: MatchupAxis,
  matrix: Report['static']['damageMatrix'],
  engineByPair: Map<string, DamageDistribution>,
): string {
  const others = axis === 'offense' ? matrix.defenders : matrix.attackers;
  const otherLabel = axis === 'offense' ? 'Defender' : 'Attacker';
  const rows: MatchupRow[] = [];
  for (let k = 0; k < others.length; k++) {
    if (k === idx) continue;
    const cell = axis === 'offense' ? matrix.cells[idx][k] : matrix.cells[k][idx];
    const engKey = axis === 'offense' ? `${monName}|${others[k]}` : `${others[k]}|${monName}`;
    rows.push({ other: others[k], cell, engine: engineByPair.get(engKey) });
  }
  rows.sort((a, b) => b.cell.percentHp - a.cell.percentHp);
  const body = rows.map(matchupTableRow).join('');
  return `
    <table class="data tight sortable">
      <thead><tr>
        <th data-default="asc">${esc(otherLabel)}</th>
        <th data-default="asc">Best Move (static)</th>
        <th data-default="desc" data-sort-on-load>%HP</th>
        <th data-default="asc">HtKO</th>
        <th data-default="desc">Engine (best implemented move)</th>
      </tr></thead>
      <tbody>${body}</tbody>
    </table>`;
}

interface MonView {
  idx: number;
  rank: StatRanks['byMon'][number];
  cov: TypeCoverage['byMon'][number];
  out: OutspeedMatrix['byMon'][number];
  cov3hko: MonOpponentList;
  vuln: MonOpponentList;
}

function indexByMon<T extends { mon: string }>(arr: T[]): Map<string, T> {
  return new Map(arr.map((x) => [x.mon, x]));
}

function buildMonViews(roster: Roster, sm: StaticMetrics): Map<string, MonView> {
  const ranks = indexByMon(sm.statRanks.byMon);
  const covs = indexByMon(sm.typeCoverage.byMon);
  const outs = indexByMon(sm.outspeed.byMon);
  const gaps = indexByMon(sm.damageDerived.coverageGapsByMon);
  const vulns = indexByMon(sm.damageDerived.vulnerabilityByMon);
  const result = new Map<string, MonView>();
  roster.mons.forEach((m, idx) => {
    result.set(m.name, {
      idx,
      rank: ranks.get(m.name)!,
      cov: covs.get(m.name)!,
      out: outs.get(m.name)!,
      cov3hko: gaps.get(m.name)!,
      vuln: vulns.get(m.name)!,
    });
  });
  return result;
}

function perMonSection(
  roster: Roster,
  mon: MonRow,
  view: MonView,
  matrix: Report['static']['damageMatrix'],
  engineByPair: Map<string, DamageDistribution>,
  unbuildableNote: string | null,
): string {
  const total = roster.mons.length;
  const opponentCount = total - 1;
  const statHtml = STAT_KEYS.map(({ key, label }) =>
    statBar(mon[key] as number, view.rank.ranks[key as string], total, label),
  ).join('');

  const offHtml = matchupTableFor(mon.name, view.idx, 'offense', matrix, engineByPair);
  const defHtml = matchupTableFor(mon.name, view.idx, 'defense', matrix, engineByPair);

  const typeHeader = `${typeBadge(mon.type1)}${typeBadge(mon.type2)}`;
  const sprite = `${SPRITE_REL}/${mon.name.toLowerCase()}_mini.gif`;
  const unbuildableTag = unbuildableNote ? `<p class="warn-banner">${esc(unbuildableNote)}</p>` : '';

  const coverageBlurb = view.cov.count === 0
    ? '<span class="muted">no super-effective coverage</span>'
    : `super-effective vs <strong>${view.cov.count}</strong> type${view.cov.count === 1 ? '' : 's'} [${view.cov.superEffectiveTypes.map(esc).join(', ')}]`;
  const synopsisLine = `<p class="mon-synopsis">Outspeeds <strong>${view.out.outspeedPct.toFixed(0)}%</strong> of roster · ${coverageBlurb}.</p>`;

  return `
    <section class="mon-card" id="mon-${esc(mon.name)}">
      <header class="mon-header">
        <img class="mon-sprite" src="${esc(sprite)}" alt="${esc(mon.name)}" onerror="this.style.display='none'">
        <div class="mon-meta">
          <h2 class="mon-name">${esc(mon.name)} <span class="mon-types">${typeHeader}</span></h2>
          <p class="mon-flavor">${esc(mon.flavor)}</p>
        </div>
      </header>
      ${unbuildableTag}
      <div class="mon-grid">
        <div class="col">
          <h3>Stats</h3>
          <div class="stats">${statHtml}</div>
          <h3>Moves</h3>
          ${monMovesTable(roster, mon)}
          ${synopsisLine}
        </div>
        <div class="col">
          <h3>Offense <small>(coverage gap: ${view.cov3hko.opponents.length}/${opponentCount} no 3HKO)</small></h3>
          ${offHtml}
          <h3>Defense <small>(${view.vuln.opponents.length}/${opponentCount} mons OHKO at avg roll)</small></h3>
          ${defHtml}
        </div>
      </div>
    </section>`;
}

const STYLE = `
  :root {
    --bg: #0e1117; --panel: #161b22; --border: #3a414b;
    --text: #f0f6fc; --muted: #adb7c2; --accent: #79b8ff;
    --flag: #ff6b62; --warn: #e3a83a; --info: #79b8ff;
    --top: #4ec56b; --bot: #ff6b62;
  }
  body { margin: 0; padding: 24px; font-family: ui-sans-serif, system-ui, -apple-system; background: var(--bg); color: var(--text); font-size: 15px; line-height: 1.5; }
  h1 { margin: 0 0 4px 0; font-size: 24px; }
  h2 { margin: 0 0 8px 0; font-size: 18px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
  h2 small { color: var(--muted); font-weight: normal; font-size: 14px; margin-left: 8px; }
  h3 { margin: 12px 0 6px 0; font-size: 15px; }
  h3 small { color: var(--muted); font-weight: normal; font-size: 13px; margin-left: 6px; }
  section { background: var(--panel); border: 1px solid var(--border); border-radius: 6px; padding: 16px; margin-bottom: 16px; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  table { border-collapse: collapse; font-size: 14px; }
  table.flags { width: 100%; }
  table.flags td, table.flags th { padding: 6px 9px; border-bottom: 1px solid var(--border); text-align: left; }
  table.flags th { background: rgba(255,255,255,0.05); font-size: 13px; color: var(--text); }
  table.flags td.sev { font-weight: bold; text-transform: uppercase; font-size: 12px; }
  table.flags tr.sev-flag td.sev { color: var(--flag); }
  table.flags tr.sev-warn td.sev { color: var(--warn); }
  table.flags tr.sev-info td.sev { color: var(--info); }
  table.flags td.rule { color: var(--muted); font-family: ui-monospace, monospace; font-size: 13px; }
  table.flags td.suggestion { color: #c9d3de; }
  table.flags tr.has-suggestion > td { border-bottom: none; }
  table.flags tr.suggestion-row > td { padding-top: 0; padding-bottom: 8px; font-size: 13px; line-height: 1.55; color: #c9d3de; }
  table.flags tr.suggestion-row .sg-arrow { color: var(--muted); margin-right: 4px; }
  table.flags ul.sg-list { margin: 0; padding: 0 0 0 18px; list-style: none; }
  table.flags ul.sg-list li { position: relative; padding: 1px 0; }
  table.flags ul.sg-list li::before { content: '↳'; position: absolute; left: -16px; color: var(--muted); }
  table.matrix { font-size: 13px; }
  table.matrix th, table.matrix td.cell { padding: 4px 6px; text-align: center; border: 1px solid var(--border); }
  table.matrix th.row-label { text-align: right; background: rgba(255,255,255,0.05); }
  table.matrix th { background: rgba(255,255,255,0.05); font-size: 12px; min-width: 64px; color: var(--text); }
  table.matrix th.row-label a { color: inherit; }
  table.matrix td.cell.self { background: #222; }
  table.matrix td.cell.empty { background: #1a1f26; color: var(--muted); }
  table.matrix td.cell.hoverable { cursor: help; }
  table.matrix td.cell .htko { display: block; font-size: 11px; opacity: 0.9; margin-top: -1px; }

  #cell-hover {
    position: absolute; display: none; z-index: 100; pointer-events: none;
    min-width: 240px; max-width: 320px;
    background: #1c2230; border: 1px solid #4a5460;
    border-radius: 6px; padding: 10px 12px;
    box-shadow: 0 6px 24px rgba(0,0,0,0.5);
    font-size: 13px; line-height: 1.45;
  }
  .hover-card .hover-head { font-size: 14px; margin-bottom: 6px; }
  .hover-card .hover-arrow { color: var(--muted); margin: 0 4px; }
  .hover-card .hover-move { font-size: 13px; margin-bottom: 8px; }
  .hover-card .hover-meta { color: var(--muted); font-size: 12px; }
  .hover-card .hover-stats {
    display: grid; grid-template-columns: 1fr 1fr; gap: 4px 12px;
    font-family: ui-monospace, monospace; font-size: 12px;
  }
  .hover-card .hover-k { color: var(--muted); margin-right: 4px; }
  .hover-card .hover-v { color: var(--text); font-weight: 600; }
  .hover-card .mult-super .hover-v { color: var(--top); }
  .hover-card .mult-resist .hover-v { color: var(--warn); }
  .hover-card .mult-immune .hover-v { color: var(--flag); }
  table.data { width: 100%; }
  table.data th, table.data td { padding: 6px 9px; border-bottom: 1px solid var(--border); text-align: left; vertical-align: top; }
  table.data th { background: rgba(255,255,255,0.05); font-size: 13px; color: var(--text); }
  table.data td.num { text-align: right; font-family: ui-monospace, monospace; }
  table.data td.num.critical { color: var(--flag); font-weight: bold; }
  table.data tr.highlight { background: rgba(248,81,73,0.10); }
  table.data tr.lowlight { background: rgba(139,148,158,0.10); }
  table.data.tight th, table.data.tight td { padding: 5px 7px; font-size: 13px; }
  table.data tr.move-row.has-desc td { border-bottom: none; padding-bottom: 2px; }
  table.data td.move-desc { font-size: 12px; color: var(--muted); padding-top: 0; padding-left: 14px; line-height: 1.45; font-style: italic; }
  .scroll { overflow-x: auto; max-width: 100%; }
  .muted { color: var(--muted); }
  .pill { display: inline-block; padding: 1px 7px; border-radius: 10px; background: rgba(255,255,255,0.07); font-size: 13px; margin-right: 4px; }
  .pill.sev-flag { color: var(--flag); }
  .pill.sev-warn { color: var(--warn); }
  .pill.sev-info { color: var(--info); }
  .toc { line-height: 2; font-size: 15px; }
  .toc-link { padding: 2px 6px; border-radius: 4px; background: rgba(255,255,255,0.05); margin-right: 2px; }

  .type-badge {
    display: inline-block; padding: 1px 7px; border-radius: 10px;
    font-size: 12px; font-weight: 600; letter-spacing: 0.02em;
    margin-right: 3px; vertical-align: middle;
  }

  .mini-sprite {
    width: 22px; height: 22px; vertical-align: middle; margin-right: 6px;
    image-rendering: pixelated; image-rendering: crisp-edges;
  }

  table.sortable th[data-default]:not([data-default="none"]) {
    cursor: pointer; user-select: none; position: relative;
  }
  table.sortable th[data-default]:not([data-default="none"]):hover { background: rgba(255,255,255,0.10); }
  table.sortable th.sort-asc::after { content: ' ▲'; opacity: 0.75; font-size: 10px; }
  table.sortable th.sort-desc::after { content: ' ▼'; opacity: 0.75; font-size: 10px; }

  .mon-card { scroll-margin-top: 16px; }
  .mon-header { display: flex; align-items: center; gap: 16px; margin-bottom: 12px; padding-bottom: 12px; border-bottom: 1px solid var(--border); }
  .mon-sprite { width: 64px; height: 64px; image-rendering: pixelated; image-rendering: crisp-edges; background: rgba(255,255,255,0.04); border-radius: 4px; }
  .mon-meta { flex: 1; min-width: 0; }
  .mon-name { margin: 0; font-size: 21px; border: none; padding: 0; }
  .mon-name .mon-types { margin-left: 10px; }
  .mon-flavor { margin: 4px 0 0 0; color: var(--muted); font-size: 14px; font-style: italic; }
  .mon-grid { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr); gap: 24px; }
  .mon-grid .col { min-width: 0; }
  .ability { margin: 0 0 8px 0; font-size: 14px; }
  .mon-synopsis { margin: 10px 0 0 0; color: var(--muted); font-size: 13px; }
  .mon-synopsis strong { color: var(--text); }
  .warn-banner { color: var(--warn); font-size: 14px; background: rgba(210,153,34,0.08); padding: 6px 10px; border-left: 2px solid var(--warn); border-radius: 3px; margin: 0 0 12px 0; }

  .stats { display: flex; flex-direction: column; gap: 4px; font-size: 14px; }
  .stat-row { display: grid; grid-template-columns: 40px 52px 64px 1fr 90px; align-items: center; gap: 8px; padding: 2px 4px; border-radius: 3px; }
  .stat-row.top { background: rgba(63,185,80,0.10); }
  .stat-row.bot { background: rgba(248,81,73,0.10); }
  .stat-label { color: var(--muted); font-size: 13px; text-transform: uppercase; letter-spacing: 0.05em; }
  .stat-value { font-family: ui-monospace, monospace; font-weight: bold; }
  .stat-rank { font-family: ui-monospace, monospace; font-size: 13px; color: var(--muted); }
  .stat-bar { height: 6px; background: rgba(255,255,255,0.07); border-radius: 3px; overflow: hidden; }
  .stat-bar-fill { height: 100%; background: var(--accent); }
  .stat-row.top .stat-bar-fill { background: var(--top); }
  .stat-row.bot .stat-bar-fill { background: var(--bot); }
  .stat-pct { font-family: ui-monospace, monospace; font-size: 13px; color: var(--muted); }
  .sb { font-size: 12px; margin-left: 4px; }
  .sb.top { color: var(--top); }
  .sb.bot { color: var(--bot); }

  details { margin-top: 12px; }
  details summary { cursor: pointer; color: var(--muted); font-size: 14px; }
  pre.json { background: #0a0d12; border: 1px solid var(--border); padding: 12px; overflow: auto; font-size: 13px; max-height: 400px; border-radius: 4px; }
`;

const HOVER_SCRIPT = `
  (function () {
    var popup = document.getElementById('cell-hover');
    if (!popup) return;
    function show(td) {
      popup.innerHTML = td.dataset.hoverHtml || '';
      popup.style.display = 'block';
      var rect = td.getBoundingClientRect();
      var pw = popup.offsetWidth, ph = popup.offsetHeight;
      var top = rect.top - ph - 8;
      if (top < 8) top = rect.bottom + 8;
      var left = rect.left + rect.width / 2 - pw / 2;
      left = Math.max(8, Math.min(window.innerWidth - pw - 8, left));
      popup.style.top = (top + window.scrollY) + 'px';
      popup.style.left = (left + window.scrollX) + 'px';
    }
    function hide() { popup.style.display = 'none'; }
    document.querySelectorAll('td.hoverable[data-hover-html]').forEach(function (td) {
      td.addEventListener('mouseenter', function () { show(td); });
      td.addEventListener('mouseleave', hide);
    });
  })();
`;

const SORT_SCRIPT = `
  function _sortValue(td) {
    var v = td.dataset.v;
    if (v === undefined) return td.innerText;
    var n = Number(v);
    return Number.isNaN(n) ? v : n;
  }
  function _sortRows(table, colIdx, dir) {
    var tbody = table.tBodies[0];
    var rows = Array.prototype.slice.call(tbody.rows);
    rows.sort(function (a, b) {
      var av = _sortValue(a.cells[colIdx]);
      var bv = _sortValue(b.cells[colIdx]);
      if (typeof av === 'number' && typeof bv === 'number') return (av - bv) * dir;
      return String(av).localeCompare(String(bv)) * dir;
    });
    rows.forEach(function (r) { tbody.appendChild(r); });
    var headers = table.querySelectorAll('thead th');
    headers.forEach(function (h, i) {
      h.classList.toggle('sort-asc', i === colIdx && dir > 0);
      h.classList.toggle('sort-desc', i === colIdx && dir < 0);
    });
    table.dataset.sortedCol = String(colIdx);
    table.dataset.sortedDir = String(dir);
  }
  document.querySelectorAll('table.sortable').forEach(function (table) {
    var headers = table.querySelectorAll('thead th');
    headers.forEach(function (h, i) {
      if (!h.dataset.default || h.dataset.default === 'none') return;
      h.addEventListener('click', function () {
        var sortedCol = Number(table.dataset.sortedCol === undefined ? -1 : table.dataset.sortedCol);
        var sortedDir = Number(table.dataset.sortedDir || 0);
        var defaultDir = h.dataset.default === 'desc' ? -1 : 1;
        var dir = sortedCol === i ? -sortedDir : defaultDir;
        _sortRows(table, i, dir);
      });
    });
    var initIdx = Array.prototype.findIndex.call(headers, function (h) { return h.hasAttribute('data-sort-on-load'); });
    if (initIdx >= 0) {
      var dir = headers[initIdx].dataset.default === 'desc' ? -1 : 1;
      _sortRows(table, initIdx, dir);
    }
  });
`;

export function renderReport(report: Report, roster: Roster): { html: string; json: string } {
  const json = JSON.stringify(report, (_k, v) => (v === Infinity ? 'Infinity' : v), 2);
  const meta = report.meta;
  const d = report.static.damageDerived;

  const engineByPair = new Map<string, DamageDistribution>();
  if (report.engine) {
    for (const c of report.engine.cells) {
      engineByPair.set(`${c.attacker}|${c.defender}`, c);
    }
  }
  const unbuildableMonNames = new Set<string>(report.engine?.unbuildableMons.map((u) => u.mon) ?? []);

  const viewByMon = buildMonViews(roster, report.static);
  const monCards = roster.mons
    .map((mon) => {
      const note = unbuildableMonNames.has(mon.name)
        ? 'Engine pass skipped this mon — its move/ability contracts are not all transpiled yet. Static metrics only.'
        : null;
      return perMonSection(roster, mon, viewByMon.get(mon.name)!, report.static.damageMatrix, engineByPair, note);
    })
    .join('');

  const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Stomp Balance Report</title>
  <style>${STYLE}</style>
</head>
<body>
  <h1>Stomp Balance Report</h1>
  <p class="muted">Generated ${esc(meta.generatedAt)} · ${meta.rosterSize} mons, ${meta.movesCount} moves${meta.seedCount !== null ? ` · ${meta.seedCount} seeds/cell` : ''} · roster 2HKO rate <strong>${num(d.twoHkoRatePct, 1)}%</strong> · hard walls <strong>${num(d.hardWallRatePct, 1)}%</strong></p>
  ${flagSection(report.flags)}
  ${damageMatrixSection(report)}
  ${tocSection(roster)}
  ${monCards}
  <details>
    <summary>Raw report data (JSON)</summary>
    <pre class="json">${esc(json)}</pre>
  </details>
  <div id="cell-hover"></div>
  <script>${HOVER_SCRIPT}${SORT_SCRIPT}</script>
</body>
</html>`;
  return { html, json };
}

export function writeReport(report: Report, roster: Roster): { htmlPath: string; jsonPath: string } {
  const { html, json } = renderReport(report, roster);
  const htmlPath = join(REPORT_DIR, 'index.html');
  const jsonPath = join(REPORT_DIR, 'data.json');
  writeFileSync(htmlPath, html);
  writeFileSync(jsonPath, json);
  return { htmlPath, jsonPath };
}
