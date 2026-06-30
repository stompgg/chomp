Stomp is designed as a Pokemon adjacent PVP turn based battler.

The goal is to bring together the intricacies of competitive pokemon while adding new wrinkles and flavor that expand beyond the original pokemon system.

Philosophically, the goal is to create a rich fully onchain game that can eventually grow to take advantage of the programmability and moneyness availed to it onchain. For example, prediction markets that resolve on who wins a game or tradable in-game assets.

The underlying game engine tries to be fully onchain when possible, eg moves and logic are onchain, but there are certain tradeoffs around data persistence and events made in the interest of gas costs. For example, moves are stored in batches and then executed at the end of the entire match. All data is stored tightly packed in structs, and games reuse storage space from old completed games. There is also a custom Solidity to TypeScript transpiler which ensures that any JS runtime can recreate the series of events that led to the current game state.

Design-wise, each mon has a unique set of abilities and moves, unlike Pokemon where there is a large overlapping move pool for different mons. The goal for each mon's design is to play into niches and tradeoffs. What can this mon do that others can't? What is the opportunity cost of taking this move (mons can have a move pool larger than 4, but only 4 moves at a time), or what is the tradeoff of this mon over the other one?

When it comes to types, there are currently 14 types, and they are unbalanced when it comes to the number of weaknesses/resistances for each one. My goal here is to start with asymmmetry when it comes to type coverage, and then balance it out on the actual mon-level. For example, Metal as a type has a lot of resistances, so it fits well with bulky mons that lack certain offensive options. Mons that have a lot of type coverage may end up with below average attacks to make up for their increased frequency of attacking for 2x damage.

Meta-wise, what are the potential team-building synergies? What is an oppressive or reductive strategy, and how can I eliminate those? How can I ensure the game has enough yomi and present the players with enough decision making? Ideally both initial team composition (gives initial advantage), and then move sequencing as well as opponent prediction are all important.

Game-wise, Stomp eschews PP in favor of a stamina system. All moves cost a certain amount of stamina, so there is an inherent trade-off for players. It also acts as a secondary resource moves and abilities can interact with. However, the system as-is has some issues: stamina, similar to life in other games like MTG rarely matters until the final points. So the tradeoff for players doesn't emerge until later on in the game, and the Rest action, designed to be a default way of stocking up stamina for later turns or recovery, fails to be as interesting of a predictive counterplay.

The default rules are: at the end of each turn, the mons in play regain 1 stamina. Resting will add an additional stamina as an action (in lieu of an attack or a switch).

There are a few ways I've thought of to improve the viability of Resting and the importance of stamina. The easiest may be to give mons a starting stamina of 3 or 4, while keeping the maximum at 5. This opens up the decision tree of the early game, as mons may decide to rest earlier if they predict some other action from the opponent.

Another idea is to empower moves to encourage players to Rest in order to gain more gameplay advantages separate from just acquiring more resources. Potentially one (or more moves per mon) has an additional mode/upgrade that's empowered after a rest, so players want to rest to then get stronger on later turns.

Matches are currently played 4v4, but eventually it may make sense to consider a 5v5 or 6v6 mode, as well as a drafting mode or a completely random mode. Doubles as a 2v2 format (with a 4 or 6 mon team) is also a work in progress (but many moves will need to be updated to support more than 1 target, both targets, etc.)

Below are general design notes for each mon:

Ghouliath:
Ghouliath is intended to be a suicide lead, of sorts. It has an ability that allows it to survive a fatal hit, a bit similar to Mimikyu or Eiscue, but triggers in a delayed fashion. The intent is to cripple the opponent with status effects when possible, and then finish off with Eternal Grudge. The +1 priority on Eternal Grudge ensures that in many situations you could potentially fire it off twice per game.

In return for this versatility, Ghouliath is intended to be less bulky with lower offensive options. It is designed to allow you to set up on later turns, and occasionally bring down an opponent with it.

Inutia:
Inutia is designed to be a versatile utility mon that can buff and heal your team. It's intended to weave in and out of battle, applying its debuff on swap. It is also designed to be less offensive, with only a few damaging options. Chain Expansion is a mix of punishing opponent swaps as well as encouraging swap-ins for the player. It's somewhat like entry hazards, but I don't think it's as dangerous, and thus is less of a main focus. (I could potentially change this and make it more of a threat.)

Inutia is comparatively bulkier, but it still has few good options for dealing damage.

Malalien:
Malalien is a glass cannon designed to buff itself and then KO as many opponents as it can. It has 3 moves designed for coverage across all types, and an attack self-buff. Its ability is designed to punish its eventual KOer conditional on Malalien having a KO itself.

Malalien is very strong as-is, especially given its speed. Only a few mons or + priority moves can take it out, and it can usually 2HKO if not OHKO every mon.

Iblivion:
Iblivion is a mon that plays with its own tertiary resource, Baselight. The goal is to make deciding when to use an empowered move interesting for the player, and to encourage more variety in move sequencing. However, as is, a free Baselight point at the end of every turn may be a bit too programmatic. Moving Baselight acquisition to be e.g. after taking damage (or some other condition) may give more room for thinking about Baselight, as it can also raise the ceiling for how strong empowered moves can get.

Currently, Loop is very strong as it gives a survivability, speed, and damage boost to Iblivion, and using it after a swap means it's already at Baselight level 2 in many cases.

Gorillax:
Gorillax is intended to be a simple bulky attacker that can hit hard. Rock Pull is intended to be a Pursuit-alike predicting move, but I think the downside of getting it wrong is rather steep. Throw Pebble was intended to be an interesting trade-off between stamina and power, but I think it may be too efficient when it is used, and it often doesn't need to be used.

Angery as an ability was designed to be a more interesting alternative to passive regeneration, but as-is, it doesn't seem to trigger often enough to be useful.

Sofabbi:
Sofabbi is designed to be a gambling adjacent mon, with a variety of RNG effects. However, as-is only Gachachacha has this high variance move, and its other moves don't really fit this existing theme. It has some sustain, some coverage with Guest Feature, but it doesn't have a coherent enough set of moves.

Pengym:
Pengym is designed to be another bulky attacker, one that can boost itself up. As is, I think Pistol Squat is a bit too strong as it's almost always the default choice. The combo of Frostbite and Deep Freeze sounds good on paper, but I think that it's somewhat slow, especially with so few other Frostbite enablers. There is probably some other synergy to combo off here, but it may need a rework.

Embursa:
Embursa is designed to be an attacker that can thrive off of being Burned. Again the goal was to add some risk/return from staying Burned. But healing from Burn automatically when Resting means that you usually only have 1 stack active.

Keeping the Rest from healing Burn (but increasing the attack boost %) may be an interesting way of handling the risk/reward curve. As is, its moves don't really benefit directly from being burned. Q5 is very strong and can be spammed. Ideally it has low stamina to justify it being used early, but it can't be armed to go off multiple turns in a row.

Volthare:
Volthare is designed to be fast and to empower the rest of your team to be fast. Overclock functions a bit like Tailwind, albeit with more of a trade-off. I think its Preemptive Shock ability is very interesting design, but the rest of its kit falls a bit flat. Zap is an interesting status that I think could be utilized more, e.g. taking half damage when Zapped.

Aurox:
Aurox is a tank that encourages taking damage, with one status healing move. I think Aurox is directionally well designed in terms of being able to sponge up damage, with a mechanic that encourages it (Up Only), but I think it's a bit too slow. Some alternative ways of converting damage received into damage dealt might be interesting, especially as Volatile Punch so often does not trigger a status, and Aurox wants to be doing a different move anyway, in most cases.

A 1.5x or 2x damage received move might already be interesting enough...

Xmon:
Xmon is designed to be a bit strange, to change up how certain mechanics work, and to interact with Sleep. I think Contagious Slumber paired with Dreamcatcher is a good synergy, although I think the passive HP regen enabled by each turn makes it a bit strong. Vital Siphon is also more annoying than powerful, but it can deadlock mons at 1 or 2 stamina which want to use a 2 or 3 stamina move.  I don't think Night Terrors is set up well. Somniphobia punishing Rest is interesting, but I don't think it is as punishing as it could be. Ideally it makes the opponent avoid Resting as much as possible for some duration. Maybe we make Resting lead to a % chance to Sleep?

As a game piece, its goal is similar to Ghouliath that it can wall certain annoying mons, and make your opponent's decisions more pointed.

Ekineki:
Ekineki is designed to be a sweeper that deals damage, with an ability that encourages holding it later in reserve. I think 999 is a bit weak (oftentimes trading off one turn of damage), especially as crits only do 1.5x in Stomp than 2x like in pokemon. I think there is more room to improve its kit options, but I do like Sneak Attack as another rule-breaking move of hitting the bench.

Nirvamma;
Nirvamma is designed moreso on flavor than a unified theme. Math type is intended to have more calculations, more moves that care about numbers and the ways we can shape things. Chronoffense is a bit too binary at the current moment, I think. Either it doesn't deal enough damage, or it'll almost certainly KO the opponent. I like Modal Bolt as a way of challenging the player to choose between different modes, but the lower status % and the damage means it's rarely the "right" choice. Hard Reset was designed to specifically force the opponent to be thrown off balance when they Rest, but I don't think it does that very well.
