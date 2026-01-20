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
    Mythic,
    Air,
    Math,
    Cyber,
    Wild,
    Cosmic,
    None
}

enum GameStatus {
    Started,
    Ended
}

enum GameMode {
    Singles,
    Doubles
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
    OnUpdateMonState
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

enum ExtraDataType {
    None,
    SelfTeamIndex
}
