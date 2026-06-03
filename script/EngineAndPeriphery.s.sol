// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/Constants.sol";

// Fundamental entities
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {BetterCPU} from "../src/cpu/BetterCPU.sol";
import {ICPURNG} from "../src/rng/ICPURNG.sol";
import {IGachaRNG} from "../src/rng/IGachaRNG.sol";
import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {SimplePM} from "../src/hooks/SimplePM.sol";
import {ReturnerGift} from "../src/game-layer/ReturnerGift.sol";

// Shared effects
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../src/effects/status/ZapStatus.sol";
import {Overclock} from "../src/effects/battlefield/Overclock.sol";

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

        Engine engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON, GAME_TIMEOUT_DURATION);
        deployedContracts.push(DeployData({name: "ENGINE", contractAddress: address(engine)}));

        SignedCommitManager commitManager = new SignedCommitManager(engine);
        deployedContracts.push(DeployData({name: "COMMIT MANAGER", contractAddress: address(commitManager)}));

        GachaTeamRegistry gachaTeamRegistry =
            new GachaTeamRegistry(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON, engine, IGachaRNG(address(0)), GachaTeamRegistry(0x575CbCB7CAE4524051bb3470d80702DfBac226bE));
        deployedContracts.push(DeployData({name: "GACHA TEAM REGISTRY", contractAddress: address(gachaTeamRegistry)}));
        
        BetterCPU betterCPU = new BetterCPU(GAME_MOVES_PER_MON, engine, ICPURNG(address(0)), typeCalc);
        deployedContracts.push(DeployData({name: "BETTER CPU", contractAddress: address(betterCPU)}));

        // Whitelist the single CPU so users can setOpponentTeam / startCustomBattle against it.
        {
            address[] memory toAllow = new address[](1);
            toAllow[0] = address(betterCPU);
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
    }
}
