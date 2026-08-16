// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../src/Constants.sol";
import "forge-std/Script.sol";

// Fundamental entities
import {Engine} from "../src/Engine.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {CPU} from "../src/cpu/CPU.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {SimplePM} from "../src/hooks/SimplePM.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {IGachaRNG} from "../src/rng/IGachaRNG.sol";
import {TypeCalculator} from "../src/types/TypeCalculator.sol";

// Shared effects
import {DefaultRuleset} from "../src/DefaultRuleset.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {ElementalField} from "../src/effects/battlefield/ElementalField.sol";
import {FluxField} from "../src/effects/battlefield/FluxField.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";
import {Storm} from "../src/effects/battlefield/Storm.sol";
import {UnstableField} from "../src/effects/battlefield/UnstableField.sol";
import {BlessedStatus} from "../src/effects/status/BlessedStatus.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";

struct DeployData {
    string name;
    address contractAddress;
}

contract EngineAndPeriphery is Script {
    DeployData[] deployedContracts;

    function run() external returns (DeployData[] memory) {
        vm.startBroadcast();

        TypeCalculator typeCalc = new TypeCalculator();
        deployedContracts.push(DeployData({name: "TYPE CALCULATOR", contractAddress: address(typeCalc)}));

        Engine engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        deployedContracts.push(DeployData({name: "ENGINE", contractAddress: address(engine)}));

        SignedCommitManager commitManager = new SignedCommitManager(engine);
        deployedContracts.push(DeployData({name: "COMMIT MANAGER", contractAddress: address(commitManager)}));

        // The previously-deployed registry players migrate their progression from. This is
        // network-specific, so deploy.py injects PREV_GACHA_TEAM_REGISTRY (read from munch's
        // address.ts for the target network). Defaults to address(0) (migration disabled) for
        // ad-hoc forge runs rather than baking in a stale, network-wrong literal.
        address previousGachaRegistry = vm.envOr("PREV_GACHA_TEAM_REGISTRY", address(0));
        GachaTeamRegistry gachaTeamRegistry = new GachaTeamRegistry(
            GAME_MONS_PER_TEAM,
            GAME_MOVES_PER_MON,
            engine,
            IGachaRNG(address(0)),
            GachaTeamRegistry(previousGachaRegistry)
        );
        deployedContracts.push(DeployData({name: "GACHA TEAM REGISTRY", contractAddress: address(gachaTeamRegistry)}));

        SignedMatchmaker signedMatchmaker = new SignedMatchmaker(engine);
        deployedContracts.push(DeployData({name: "SIGNED MATCHMAKER", contractAddress: address(signedMatchmaker)}));

        // The CPU approves the SignedMatchmaker at construction (D34) so signed Multi offers
        // seating it pass the engine's per-seat matchmaker gate.
        address[] memory cpuMatchmakers = new address[](1);
        cpuMatchmakers[0] = address(signedMatchmaker);
        CPU cpu = new CPU(engine, cpuMatchmakers);
        deployedContracts.push(DeployData({name: "CPU", contractAddress: address(cpu)}));

        // Whitelist the single CPU so users can setOpponentTeam / startCustomBattle against it.
        {
            address[] memory toAllow = new address[](1);
            toAllow[0] = address(cpu);
            address[] memory toDisallow = new address[](0);
            gachaTeamRegistry.setWhitelistedOpponents(toAllow, toDisallow);
        }

        SimplePM simplePM = new SimplePM(engine);
        deployedContracts.push(DeployData({name: "SIMPLE PM", contractAddress: address(simplePM)}));

        deployGameFundamentals(engine);

        vm.stopBroadcast();
        return deployedContracts;
    }

    function deployGameFundamentals(Engine engine) public {
        Overclock overclock = new Overclock();
        deployedContracts.push(DeployData({name: "OVERCLOCK", contractAddress: address(overclock)}));

        Storm storm = new Storm();
        deployedContracts.push(DeployData({name: "STORM", contractAddress: address(storm)}));

        SleepStatus sleepStatus = new SleepStatus();
        deployedContracts.push(DeployData({name: "SLEEP STATUS", contractAddress: address(sleepStatus)}));

        PanicStatus panicStatus = new PanicStatus();
        deployedContracts.push(DeployData({name: "PANIC STATUS", contractAddress: address(panicStatus)}));

        FrostbiteStatus frostbiteStatus = new FrostbiteStatus();
        deployedContracts.push(DeployData({name: "FROSTBITE STATUS", contractAddress: address(frostbiteStatus)}));

        BurnStatus burnStatus = new BurnStatus();
        deployedContracts.push(DeployData({name: "BURN STATUS", contractAddress: address(burnStatus)}));

        ZapStatus zapStatus = new ZapStatus();
        deployedContracts.push(DeployData({name: "ZAP STATUS", contractAddress: address(zapStatus)}));

        BlessedStatus blessedStatus = new BlessedStatus();
        deployedContracts.push(DeployData({name: "BLESSED STATUS", contractAddress: address(blessedStatus)}));

        deployBattlefieldFields(engine, sleepStatus, panicStatus, frostbiteStatus, burnStatus, zapStatus);
    }

    /// @dev Optional battlefield fields, each paired with the ruleset a client selects it by. The
    ///      marker entry in each ruleset is what keeps the Engine's inline stamina regen: full for
    ///      Elemental / Unstable, resting-only for Flux (which owns round-end stamina itself).
    function deployBattlefieldFields(
        Engine engine,
        SleepStatus sleepStatus,
        PanicStatus panicStatus,
        FrostbiteStatus frostbiteStatus,
        BurnStatus burnStatus,
        ZapStatus zapStatus
    ) internal {
        ElementalField elementalField =
            new ElementalField(burnStatus, frostbiteStatus, sleepStatus, panicStatus, zapStatus);
        deployedContracts.push(DeployData({name: "ELEMENTAL FIELD", contractAddress: address(elementalField)}));

        UnstableField unstableField = new UnstableField();
        deployedContracts.push(DeployData({name: "UNSTABLE FIELD", contractAddress: address(unstableField)}));

        FluxField fluxField = new FluxField();
        deployedContracts.push(DeployData({name: "FLUX FIELD", contractAddress: address(fluxField)}));

        deployedContracts.push(
            DeployData({
                name: "ELEMENTAL FIELD RULESET",
                contractAddress: address(_fieldRuleset(engine, elementalField, INLINE_STAMINA_REGEN_RULESET))
            })
        );
        deployedContracts.push(
            DeployData({
                name: "UNSTABLE FIELD RULESET",
                contractAddress: address(_fieldRuleset(engine, unstableField, INLINE_STAMINA_REGEN_RULESET))
            })
        );
        deployedContracts.push(
            DeployData({
                name: "FLUX FIELD RULESET",
                contractAddress: address(_fieldRuleset(engine, fluxField, INLINE_REST_REGEN_MARKER))
            })
        );
    }

    function _fieldRuleset(Engine engine, IEffect field, address regenMarker) internal returns (DefaultRuleset) {
        IEffect[] memory effects = new IEffect[](2);
        effects[0] = IEffect(regenMarker);
        effects[1] = field;
        return new DefaultRuleset(engine, effects);
    }
}
