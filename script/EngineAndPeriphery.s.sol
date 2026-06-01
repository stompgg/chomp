// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../src/Constants.sol";

// Fundamental entities
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {OkayCPU} from "../src/cpu/OkayCPU.sol";
import {BetterCPU} from "../src/cpu/BetterCPU.sol";
import {FairCPU} from "../src/cpu/FairCPU.sol";
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
            new GachaTeamRegistry(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON, engine, IGachaRNG(address(0)));
        deployedContracts.push(DeployData({name: "GACHA TEAM REGISTRY", contractAddress: address(gachaTeamRegistry)}));

        // DefaultRandomnessOracle defaultOracle = new DefaultRandomnessOracle();
        // deployedContracts.push(DeployData({name: "DEFAULT RANDOMNESS ORACLE", contractAddress: address(defaultOracle)}));

        OkayCPU okayCPU = new OkayCPU(GAME_MOVES_PER_MON, engine, ICPURNG(address(0)), typeCalc);
        deployedContracts.push(DeployData({name: "OKAY CPU", contractAddress: address(okayCPU)}));

        BetterCPU betterCPU = new BetterCPU(GAME_MOVES_PER_MON, engine, ICPURNG(address(0)), typeCalc);
        deployedContracts.push(DeployData({name: "BETTER CPU", contractAddress: address(betterCPU)}));

        // Diyu D5: per-mon setup moves. Value is stored as (slot + 1); see BetterCPU.monConfig.
        // setMonConfig writes plain storage and does not require the mon to be registered yet.
        uint256 setupKey = betterCPU.CONFIG_SETUP_MOVE();
        betterCPU.setMonConfig(1,  setupKey, 2); // Inutia    -> Initialize    (slot 1)
        betterCPU.setMonConfig(2,  setupKey, 1); // Malalien  -> Triple Think  (slot 0)
        betterCPU.setMonConfig(3,  setupKey, 2); // Iblivion  -> Loop          (slot 1)
        betterCPU.setMonConfig(6,  setupKey, 2); // Pengym    -> Deadlift      (slot 1)
        betterCPU.setMonConfig(7,  setupKey, 3); // Embursa   -> Heat Beacon   (slot 2)
        betterCPU.setMonConfig(9,  setupKey, 3); // Aurox     -> Iron Wall     (slot 2)
        betterCPU.setMonConfig(11, setupKey, 3); // Ekineki   -> Nine Nine Nine (slot 2)
        betterCPU.setMonConfig(12, setupKey, 1); // Nirvamma  -> Hard Reset    (slot 0)

        // FairCPU: heuristic CPU that does not peek at the player's current-turn revealed move.
        // Shares HeuristicCPUBase storage layout with BetterCPU but ignores playerMoveIndex/
        // playerExtraData. Skips the per-mon SETUP_MOVE config — FairCPU deletes the Diyu
        // free-turn branch entirely, so those configs would be dead writes.
        FairCPU fairCPU = new FairCPU(GAME_MOVES_PER_MON, engine, ICPURNG(address(0)), typeCalc);
        deployedContracts.push(DeployData({name: "FAIR CPU", contractAddress: address(fairCPU)}));

        // Whitelist all CPUs so users can setOpponentTeam against them.
        {
            address[] memory toAllow = new address[](3);
            toAllow[0] = address(okayCPU);
            toAllow[1] = address(betterCPU);
            toAllow[2] = address(fairCPU);
            address[] memory toDisallow = new address[](0);
            gachaTeamRegistry.setWhitelistedOpponents(toAllow, toDisallow);
        }

        SignedMatchmaker signedMatchmaker = new SignedMatchmaker(engine);
        deployedContracts.push(DeployData({name: "SIGNED MATCHMAKER", contractAddress: address(signedMatchmaker)}));

        // SimplePM simplePM = new SimplePM(engine);
        // deployedContracts.push(DeployData({name: "SIMPLE PM", contractAddress: address(simplePM)}));

        ReturnerGift returnerGift = new ReturnerGift(address(gachaTeamRegistry));
        deployedContracts.push(DeployData({name: "RETURNER GIFT", contractAddress: address(returnerGift)}));

        {
            address[] memory toAllow = new address[](1);
            toAllow[0] = address(returnerGift);
            address[] memory toDisallow = new address[](0);
            gachaTeamRegistry.setAssigners(toAllow, toDisallow);
        }
        returnerGift.setMerkleRoot(0xa5a0a4a18ff338c23790a0561e53748033ed3764ed3cbae49f06afcff7c7d773);

        deployGameFundamentals();
        
        vm.stopBroadcast();
        return deployedContracts;
    }

    function deployGameFundamentals() public {

        // Stat boosts are now inlined into the Engine (no standalone StatBoosts contract to deploy).

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
