pragma solidity 0.8.24;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MockToken} from "../src/MockToken.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {ScriptBase} from "./ScriptBase.sol";

contract DeployLocal is ScriptBase {
    function run() external returns (MockToken token, TripFundV1 fund, address proxyAdmin) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(key);
        uint256 goal = vm.envOr("GOAL", uint256(100 ether));
        uint256 deadline = vm.envOr("DEADLINE", block.timestamp + 7 days);

        vm.startBroadcast(key);
        token = new MockToken();
        token.mint(owner, 1_000 ether);
        TripFundV1 implementation = new TripFundV1();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            owner,
            abi.encodeCall(TripFundV1.initialize, (address(token), owner, goal, deadline))
        );
        vm.stopBroadcast();

        fund = TripFundV1(address(proxy));
        proxyAdmin = address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT))));
    }
}
