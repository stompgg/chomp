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
import {Overclock} from "../src/effects/battlefield/Overclock.sol";
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

        CPU cpu = new CPU(engine);
        deployedContracts.push(DeployData({name: "CPU", contractAddress: address(cpu)}));

        // Whitelist the single CPU so users can setOpponentTeam / startCustomBattle against it.
        {
            address[] memory toAllow = new address[](1);
            toAllow[0] = address(cpu);
            address[] memory toDisallow = new address[](0);
            gachaTeamRegistry.setWhitelistedOpponents(toAllow, toDisallow);
        }

        SignedMatchmaker signedMatchmaker = new SignedMatchmaker(engine);
        deployedContracts.push(DeployData({name: "SIGNED MATCHMAKER", contractAddress: address(signedMatchmaker)}));

        SimplePM simplePM = new SimplePM(engine);
        deployedContracts.push(DeployData({name: "SIMPLE PM", contractAddress: address(simplePM)}));

        deployGameFundamentals();

        vm.stopBroadcast();
        return deployedContracts;
    }

    function deployGameFundamentals() public {
        Overclock overclock = new Overclock();
        deployedContracts.push(DeployData({name: "OVERCLOCK", contractAddress: address(overclock)}));

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
    }
}
