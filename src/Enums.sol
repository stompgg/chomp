// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

enum Type {
    Yin,
    Yang,
    Earth,
    Liquid,
    Fire,
    Metal,
    Ice,
    Nature,
    Lightning,
    Faith,
    Air,
    Math,
    Cyber,
    Cosmic,
    None
}

enum GameStatus {
    Started,
    Ended
}

enum EffectStep {
    OnApply,
    RoundStart,
    RoundEnd,
    OnRemove,
    OnMonSwitchIn,
    OnMonSwitchOut,
    AfterDamage,
    AfterMove,
    OnUpdateMonState,
    PreDamage
}

enum MoveClass {
    Physical,
    Special,
    Self,
    Other
}

enum MonStateIndexName {
    Hp,
    Stamina,
    Speed,
    Attack,
    Defense,
    SpecialAttack,
    SpecialDefense,
    IsKnockedOut,
    ShouldSkipTurn,
    Type1,
    Type2
}

enum EffectRunCondition {
    SkipIfGameOver, // Default to always run
    SkipIfGameOverOrMonKO // Skips if mon is KO'ed
}

enum StatBoostType {
    Multiply,
    Divide
}

enum StatBoostFlag {
    Temp,
    Perm
}

enum EngineHookStep {
    OnBattleStart,
    OnRoundStart,
    OnRoundEnd,
    OnBattleEnd
}

// Legal target domain for a move's targetBits nibble (top 4 bits of extraData).
// AnyOtherSlot is 0 so inline move words (all StandardAttack-shaped) default to it (D28).
// In singles the nibble is ignored and targeting is implied (the opposing active).
enum TargetSpec {
    AnyOtherSlot, // exactly 1 bit: either opposing slot or the ally slot (not self)
    None, // no slot target: targetBits must be 0 (payload-driven or untargeted moves)
    SelfOnly, // exactly 1 bit: the attacker's own slot
    OpponentSlot, // exactly 1 bit: an opposing slot
    AllySlot, // exactly 1 bit: the ally slot
    AnySubset // any nonzero subset of the 4 slots (multi-target capable)
}
