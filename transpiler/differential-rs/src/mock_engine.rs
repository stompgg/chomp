//! PanicEngine: an IEngine implementation whose every method panics.
//! Pure-lib differential tests need a `&mut dyn IEngine` to satisfy
//! signatures on paths that never touch the engine (e.g. MoveSlotLib
//! inline decoding). Any actual call is a test bug and fails loudly.
//!
//! Generated from the emitted IEngine trait (scripts/gen_mock_engine.py
//! regenerates it if the trait surface changes).

use chomp_engine::IEngine::IEngine;
use chomp_engine::Enums::*;
use chomp_engine::Structs::*;
use chomp_rt::{Address, B256, I256, U256};

pub struct PanicEngine;

impl IEngine for PanicEngine {
    fn battleKeyForWrite(&self) -> B256 {
        unimplemented!("PanicEngine.battleKeyForWrite called from a pure-lib test")
    }
    fn tempRNG(&self) -> U256 {
        unimplemented!("PanicEngine.tempRNG called from a pure-lib test")
    }
    fn getPreDamage(&self) -> i32 {
        unimplemented!("PanicEngine.getPreDamage called from a pure-lib test")
    }
    fn setPreDamage(&mut self, value: i32) {
        unimplemented!("PanicEngine.setPreDamage called from a pure-lib test")
    }
    fn updateMatchmakers(&mut self, makersToAdd: &mut Vec<Address>, makersToRemove: &mut Vec<Address>) {
        unimplemented!("PanicEngine.updateMatchmakers called from a pure-lib test")
    }
    fn startBattle(&mut self, battle: &mut Battle) {
        unimplemented!("PanicEngine.startBattle called from a pure-lib test")
    }
    fn updateMonState(&mut self, playerIndex: U256, monIndex: U256, stateVarIndex: MonStateIndexName, valueToAdd: i32) {
        unimplemented!("PanicEngine.updateMonState called from a pure-lib test")
    }
    fn addEffect(&mut self, targetIndex: U256, monIndex: U256, effect: Address, extraData: B256) {
        unimplemented!("PanicEngine.addEffect called from a pure-lib test")
    }
    fn removeEffect(&mut self, targetIndex: U256, monIndex: U256, effectIndex: U256) {
        unimplemented!("PanicEngine.removeEffect called from a pure-lib test")
    }
    fn editEffect(&mut self, targetIndex: U256, effectIndex: U256, newExtraData: B256) {
        unimplemented!("PanicEngine.editEffect called from a pure-lib test")
    }
    fn setGlobalKV(&mut self, key: u64, value: U256) {
        unimplemented!("PanicEngine.setGlobalKV called from a pure-lib test")
    }
    fn addStatBoost(&mut self, targetIndex: U256, monIndex: U256, statBoostsToApply: &mut Vec<StatBoostToApply>, boostFlag: StatBoostFlag) {
        unimplemented!("PanicEngine.addStatBoost called from a pure-lib test")
    }
    fn removeStatBoost(&mut self, targetIndex: U256, monIndex: U256, boostFlag: StatBoostFlag) {
        unimplemented!("PanicEngine.removeStatBoost called from a pure-lib test")
    }
    fn clearAllStatBoosts(&mut self, targetIndex: U256, monIndex: U256) {
        unimplemented!("PanicEngine.clearAllStatBoosts called from a pure-lib test")
    }
    fn dealDamage(&mut self, playerIndex: U256, monIndex: U256, damage: i32) {
        unimplemented!("PanicEngine.dealDamage called from a pure-lib test")
    }
    fn dispatchStandardAttack(&mut self, attackerPlayerIndex: U256, defenderMonIndex: U256, basePower: u32, accuracy: u32, volatility: u32, moveType: Type, moveClass: MoveClass, critRate: U256, effectAccuracy: u8, effect: Address, rng: U256) -> (i32, B256) {
        unimplemented!("PanicEngine.dispatchStandardAttack called from a pure-lib test")
    }
    fn dispatchCustomAttack(&mut self, attackerPlayerIndex: U256, basePower: u32, accuracy: u32, volatility: U256, moveType: Type, moveClass: MoveClass, rng: U256, critRate: U256) -> (i32, B256) {
        unimplemented!("PanicEngine.dispatchCustomAttack called from a pure-lib test")
    }
    fn switchActiveMon(&mut self, playerIndex: U256, monToSwitchIndex: U256) {
        unimplemented!("PanicEngine.switchActiveMon called from a pure-lib test")
    }
    fn setMove(&mut self, battleKey: B256, playerIndex: U256, moveIndex: u8, salt: u128, extraData: u16) {
        unimplemented!("PanicEngine.setMove called from a pure-lib test")
    }
    fn execute(&mut self, battleKey: B256) -> Address {
        unimplemented!("PanicEngine.execute called from a pure-lib test")
    }
    fn executeWithMoves(&mut self, battleKey: B256, p0MoveIndex: u8, p0Salt: u128, p0ExtraData: u16, p1MoveIndex: u8, p1Salt: u128, p1ExtraData: u16) -> Address {
        unimplemented!("PanicEngine.executeWithMoves called from a pure-lib test")
    }
    fn executeWithSingleMove(&mut self, battleKey: B256, moveIndex: u8, salt: u128, extraData: u16) -> Address {
        unimplemented!("PanicEngine.executeWithSingleMove called from a pure-lib test")
    }
    fn executeBatchedTurns(&mut self, battleKey: B256, entries: &mut Vec<U256>) -> (u64, Address) {
        unimplemented!("PanicEngine.executeBatchedTurns called from a pure-lib test")
    }
    fn resetCallContext(&mut self) {
        unimplemented!("PanicEngine.resetCallContext called from a pure-lib test")
    }
    fn submitTurnMoves(&mut self, battleKey: B256, packedMoves: U256, r: B256, vs: B256) {
        unimplemented!("PanicEngine.submitTurnMoves called from a pure-lib test")
    }
    fn submitTurnMovesAndExecute(&mut self, battleKey: B256, packedMoves: U256, r: B256, vs: B256) {
        unimplemented!("PanicEngine.submitTurnMovesAndExecute called from a pure-lib test")
    }
    fn executeBuffered(&mut self, battleKey: B256) {
        unimplemented!("PanicEngine.executeBuffered called from a pure-lib test")
    }
    fn getBufferedTurns(&self, battleKey: B256) -> (u64, Vec<U256>) {
        unimplemented!("PanicEngine.getBufferedTurns called from a pure-lib test")
    }
    fn pairHashNonces(&self, pairHash: B256) -> U256 {
        unimplemented!("PanicEngine.pairHashNonces called from a pure-lib test")
    }
    fn computeBattleKey(&self, p0: Address, p1: Address) -> (B256, B256) {
        unimplemented!("PanicEngine.computeBattleKey called from a pure-lib test")
    }
    fn computePriorityPlayerIndex(&self, battleKey: B256, rng: U256) -> U256 {
        unimplemented!("PanicEngine.computePriorityPlayerIndex called from a pure-lib test")
    }
    fn getStorageKey(&self, battleKey: B256) -> B256 {
        unimplemented!("PanicEngine.getStorageKey called from a pure-lib test")
    }
    fn getBattle(&self, battleKey: B256) -> (BattleConfigView, BattleData) {
        unimplemented!("PanicEngine.getBattle called from a pure-lib test")
    }
    fn getMonValueForBattle(&self, battleKey: B256, playerIndex: U256, monIndex: U256, stateVarIndex: MonStateIndexName) -> u32 {
        unimplemented!("PanicEngine.getMonValueForBattle called from a pure-lib test")
    }
    fn getMonStatsForBattle(&self, battleKey: B256, playerIndex: U256, monIndex: U256) -> MonStats {
        unimplemented!("PanicEngine.getMonStatsForBattle called from a pure-lib test")
    }
    fn getMonStateForBattle(&self, battleKey: B256, playerIndex: U256, monIndex: U256, stateVarIndex: MonStateIndexName) -> i32 {
        unimplemented!("PanicEngine.getMonStateForBattle called from a pure-lib test")
    }
    fn getMoveForMonForBattle(&self, battleKey: B256, playerIndex: U256, monIndex: U256, moveIndex: U256) -> U256 {
        unimplemented!("PanicEngine.getMoveForMonForBattle called from a pure-lib test")
    }
    fn getMoveDecisionForBattleState(&self, battleKey: B256, playerIndex: U256) -> MoveDecision {
        unimplemented!("PanicEngine.getMoveDecisionForBattleState called from a pure-lib test")
    }
    fn getTeamSize(&self, battleKey: B256, playerIndex: U256) -> U256 {
        unimplemented!("PanicEngine.getTeamSize called from a pure-lib test")
    }
    fn getTurnIdForBattleState(&self, battleKey: B256) -> U256 {
        unimplemented!("PanicEngine.getTurnIdForBattleState called from a pure-lib test")
    }
    fn getActiveMonIndexForBattleState(&self, battleKey: B256) -> Vec<U256> {
        unimplemented!("PanicEngine.getActiveMonIndexForBattleState called from a pure-lib test")
    }
    fn getGlobalKV(&self, battleKey: B256, key: u64) -> U256 {
        unimplemented!("PanicEngine.getGlobalKV called from a pure-lib test")
    }
    fn validatePlayerMoveForBattle(&mut self, battleKey: B256, moveIndex: U256, playerIndex: U256, extraData: u16) -> bool {
        unimplemented!("PanicEngine.validatePlayerMoveForBattle called from a pure-lib test")
    }
    fn getEffects(&self, battleKey: B256, targetIndex: U256, monIndex: U256) -> (Vec<EffectInstance>, Vec<U256>) {
        unimplemented!("PanicEngine.getEffects called from a pure-lib test")
    }
    fn getEffectData(&self, battleKey: B256, targetIndex: U256, monIndex: U256, effectAddr: Address) -> (bool, U256, B256) {
        unimplemented!("PanicEngine.getEffectData called from a pure-lib test")
    }
    fn getWinner(&self, battleKey: B256) -> Address {
        unimplemented!("PanicEngine.getWinner called from a pure-lib test")
    }
    fn getKOBitmap(&self, battleKey: B256, playerIndex: U256) -> U256 {
        unimplemented!("PanicEngine.getKOBitmap called from a pure-lib test")
    }
    fn getBattleContext(&self, battleKey: B256) -> BattleContext {
        unimplemented!("PanicEngine.getBattleContext called from a pure-lib test")
    }
    fn getDamageCalcContext(&self, battleKey: B256, attackerPlayerIndex: U256, defenderPlayerIndex: U256) -> DamageCalcContext {
        unimplemented!("PanicEngine.getDamageCalcContext called from a pure-lib test")
    }
    fn getBattleEndContext(&self, battleKey: B256) -> BattleEndContext {
        unimplemented!("PanicEngine.getBattleEndContext called from a pure-lib test")
    }
    fn getMonStatesForSide(&self, battleKey: B256, playerIndex: U256) -> Vec<MonState> {
        unimplemented!("PanicEngine.getMonStatesForSide called from a pure-lib test")
    }
}
