// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {IEngine} from "../src/IEngine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IValidator} from "../src/IValidator.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {SignedCommitLib} from "../src/commit-manager/SignedCommitLib.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

/// @notice Tests + gas comparison for `Engine.executeWithDualSignedMovesDirect` — the
///         opt-in path where battles started with `moveManager = address(0)` skip the
///         manager STATICCALL and have the engine do auth + sig verification itself.
contract EngineDualSignedDirectTest is Test {
    Engine engine;
    SignedCommitManager mgr;  // used for the comparison path
    SignedMatchmaker maker;
    DefaultValidator validator;
    DefaultRandomnessOracle defaultOracle;
    ITypeCalculator typeCalc;
    TestTeamRegistry registry;
    StandardAttackFactory factory;

    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 2;

    IMoveSet moveA;
    IMoveSet moveB;

    // EIP-712 domain typehash mirror; the engine uses ("Engine","1") as its domain.
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON, TIMEOUT_DURATION: 10})
        );
        typeCalc = new TypeCalculator();
        registry = new TestTeamRegistry();
        factory = new StandardAttackFactory(typeCalc);

        moveA = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "A", EFFECT: IEffect(address(0))
            })
        );
        moveB = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 25, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "B", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon();
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));
        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        registry.setTeam(p0, team);
        registry.setTeam(p1, team);
    }

    function _createMon() internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 100000, stamina: 20, speed: 10, attack: 30, defense: 10,
                specialAttack: 30, specialDefense: 10, type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
    }

    function _startBattle(address moveManager) internal returns (bytes32) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(maker);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, new address[](0));

        (bytes32 battleKey, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);
        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0, p0TeamIndex: 0,
                p1: p1, p1TeamIndex: 0,
                teamRegistry: registry, validator: validator,
                rngOracle: defaultOracle, ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
                moveManager: moveManager,
                matchmaker: maker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: nonce
        });
        bytes32 digest = maker.hashTypedData(BattleOfferLib.hashBattleOffer(offer));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(p1);
        maker.startGame(offer, sig);
        return battleKey;
    }

    // ---- Engine EIP-712 signing ----------------------------------------

    function _engineDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("Engine")),
                keccak256(bytes("1")),
                block.chainid,
                address(engine)
            )
        );
    }

    function _signDualRevealForEngine(
        uint256 privateKey,
        bytes32 battleKey,
        uint64 turnId,
        bytes32 committerMoveHash,
        uint8 revealerMoveIndex,
        uint104 revealerSalt,
        uint16 revealerExtraData
    ) internal view returns (bytes memory) {
        bytes32 structHash = SignedCommitLib.hashDualSignedReveal(
            SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: revealerMoveIndex,
                revealerSalt: revealerSalt,
                revealerExtraData: revealerExtraData
            })
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _engineDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ---- Manager EIP-712 signing (for comparison) ----------------------

    function _signDualRevealForManager(
        uint256 privateKey,
        bytes32 battleKey,
        uint64 turnId,
        bytes32 committerMoveHash,
        uint8 revealerMoveIndex,
        uint104 revealerSalt,
        uint16 revealerExtraData
    ) internal view returns (bytes memory) {
        bytes32 domainSep = keccak256(abi.encode(
            DOMAIN_TYPEHASH,
            keccak256(bytes("SignedCommitManager")),
            keccak256(bytes("1")),
            block.chainid,
            address(mgr)
        ));
        bytes32 structHash = SignedCommitLib.hashDualSignedReveal(
            SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: revealerMoveIndex,
                revealerSalt: revealerSalt,
                revealerExtraData: revealerExtraData
            })
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ---- Functional tests -----------------------------------------------

    function test_direct_lead_select_works() public {
        bytes32 battleKey = _startBattle(address(0));

        // Turn 0 is the lead-select switch. Committer = p0 (turnId 0 % 2 == 0).
        uint64 turnId = 0;
        uint8 cMove = SWITCH_MOVE_INDEX;
        uint104 cSalt = uint104(uint256(keccak256("c0")));
        uint16 cExtra = 0;
        uint8 rMove = SWITCH_MOVE_INDEX;
        uint104 rSalt = uint104(uint256(keccak256("r0")));
        uint16 rExtra = 0;
        bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, cExtra));
        bytes memory rSig = _signDualRevealForEngine(P1_PK, battleKey, turnId, cHash, rMove, rSalt, rExtra);

        vm.prank(p0);
        engine.executeWithDualSignedMovesDirect(battleKey, cMove, cSalt, cExtra, rMove, rSalt, rExtra, rSig);
        engine.resetCallContext();

        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "turnId advanced");
        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[0], 0, "p0 active");
        assertEq(active[1], 0, "p1 active");
    }

    function test_direct_reverts_when_moveManager_set() public {
        bytes32 battleKey = _startBattle(address(mgr));

        uint8 cMove = SWITCH_MOVE_INDEX;
        uint104 cSalt = uint104(uint256(keccak256("c0")));
        bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, uint16(0)));
        bytes memory rSig = _signDualRevealForEngine(P1_PK, battleKey, 0, cHash, SWITCH_MOVE_INDEX, uint104(0), 0);

        vm.prank(p0);
        vm.expectRevert(Engine.MoveManagerSet.selector);
        engine.executeWithDualSignedMovesDirect(battleKey, cMove, cSalt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, rSig);
    }

    function test_direct_reverts_on_wrong_sig() public {
        bytes32 battleKey = _startBattle(address(0));

        uint8 cMove = SWITCH_MOVE_INDEX;
        uint104 cSalt = uint104(uint256(keccak256("c0")));
        bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, uint16(0)));
        // Sign with committer's key instead of revealer's — should fail.
        bytes memory wrongSig = _signDualRevealForEngine(P0_PK, battleKey, 0, cHash, SWITCH_MOVE_INDEX, uint104(0), 0);

        vm.prank(p0);
        vm.expectRevert(Engine.InvalidRevealerSignature.selector);
        engine.executeWithDualSignedMovesDirect(
            battleKey, cMove, cSalt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, wrongSig
        );
    }

    function test_direct_reverts_when_caller_not_committer() public {
        bytes32 battleKey = _startBattle(address(0));

        uint8 cMove = SWITCH_MOVE_INDEX;
        uint104 cSalt = uint104(uint256(keccak256("c0")));
        bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, uint16(0)));
        bytes memory rSig = _signDualRevealForEngine(P1_PK, battleKey, 0, cHash, SWITCH_MOVE_INDEX, uint104(0), 0);

        // turnId 0 → committer is p0. p1 calling should revert.
        vm.prank(p1);
        vm.expectRevert(Engine.WrongCaller.selector);
        engine.executeWithDualSignedMovesDirect(battleKey, cMove, cSalt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, rSig);
    }

    function test_direct_signed_for_manager_domain_fails() public {
        // Sig generated for manager's EIP-712 domain shouldn't verify on the engine — different
        // domain separator. Defends against cross-contamination if someone tries to relay a
        // manager-bound sig to the engine's direct path.
        bytes32 battleKey = _startBattle(address(0));

        uint8 cMove = SWITCH_MOVE_INDEX;
        uint104 cSalt = uint104(uint256(keccak256("c0")));
        bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, uint16(0)));
        bytes memory managerSig = _signDualRevealForManager(P1_PK, battleKey, 0, cHash, SWITCH_MOVE_INDEX, uint104(0), 0);

        vm.prank(p0);
        vm.expectRevert(Engine.InvalidRevealerSignature.selector);
        engine.executeWithDualSignedMovesDirect(battleKey, cMove, cSalt, 0, SWITCH_MOVE_INDEX, uint104(0), 0, managerSig);
    }

    // ---- Gas comparison: direct vs manager ------------------------------

    /// @dev Drive N two-player turns through both flows and report per-flow gas.
    function _measureDirect(uint256 nTurns) internal returns (uint256 totalGas) {
        bytes32 battleKey = _startBattle(address(0));
        // Lead-in switch (not counted).
        _executeDirectTurn(battleKey, 0, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX);

        uint256 startGas = gasleft();
        for (uint64 i = 1; i <= nTurns; i++) {
            uint8 cMove = uint8((i + 1) % 2);
            uint8 rMove = uint8(i % 2);
            _executeDirectTurn(battleKey, i, cMove, rMove);
        }
        return startGas - gasleft();
    }

    function _measureManager(uint256 nTurns) internal returns (uint256 totalGas) {
        bytes32 battleKey = _startBattle(address(mgr));
        _executeManagerTurn(battleKey, 0, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX);

        uint256 startGas = gasleft();
        for (uint64 i = 1; i <= nTurns; i++) {
            uint8 cMove = uint8((i + 1) % 2);
            uint8 rMove = uint8(i % 2);
            _executeManagerTurn(battleKey, i, cMove, rMove);
        }
        return startGas - gasleft();
    }

    function _executeDirectTurn(bytes32 battleKey, uint64 turnId, uint8 cMoveIdx, uint8 rMoveIdx) internal {
        (uint256 cPk, uint256 rPk) = turnId % 2 == 0 ? (P0_PK, P1_PK) : (P1_PK, P0_PK);
        uint104 cSalt = uint104(uint256(keccak256(abi.encode("c", battleKey, turnId))));
        uint104 rSalt = uint104(uint256(keccak256(abi.encode("r", battleKey, turnId))));
        bytes32 cHash = keccak256(abi.encodePacked(cMoveIdx, cSalt, uint16(0)));
        bytes memory rSig = _signDualRevealForEngine(rPk, battleKey, turnId, cHash, rMoveIdx, rSalt, 0);
        vm.prank(vm.addr(cPk));
        engine.executeWithDualSignedMovesDirect(battleKey, cMoveIdx, cSalt, 0, rMoveIdx, rSalt, 0, rSig);
        engine.resetCallContext();
    }

    function _executeManagerTurn(bytes32 battleKey, uint64 turnId, uint8 cMoveIdx, uint8 rMoveIdx) internal {
        (uint256 cPk, uint256 rPk) = turnId % 2 == 0 ? (P0_PK, P1_PK) : (P1_PK, P0_PK);
        uint104 cSalt = uint104(uint256(keccak256(abi.encode("c", battleKey, turnId))));
        uint104 rSalt = uint104(uint256(keccak256(abi.encode("r", battleKey, turnId))));
        bytes32 cHash = keccak256(abi.encodePacked(cMoveIdx, cSalt, uint16(0)));
        bytes memory rSig = _signDualRevealForManager(rPk, battleKey, turnId, cHash, rMoveIdx, rSalt, 0);
        vm.prank(vm.addr(cPk));
        mgr.executeWithDualSignedMoves(battleKey, cMoveIdx, cSalt, 0, rMoveIdx, rSalt, 0, rSig);
        engine.resetCallContext();
    }

    function test_gasComparison_B14() public {
        uint256 directGas = _measureDirect(14);
        uint256 managerGas = _measureManager(14);
        console.log("=== PvP dual-signed B=14 ===");
        console.log("  via manager (single-tx warmth) :", managerGas);
        console.log("  via engine direct              :", directGas);
        if (directGas < managerGas) {
            console.log("  saved                          :", managerGas - directGas);
            console.log("  per-turn saved                 :", (managerGas - directGas) / 14);
        } else {
            console.log("  REGRESSED by                   :", directGas - managerGas);
        }
    }
}
