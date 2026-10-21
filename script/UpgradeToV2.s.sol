pragma solidity 0.8.24;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {ScriptBase} from "./ScriptBase.sol";

contract UpgradeToV2 is ScriptBase {
    function run() external returns (TripFundV2 implementation, TripFundV2 fund) {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("PROXY");
        require(block.timestamp < TripFundV1(proxy).deadline(), "deadline already reached");
        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));
        require(admin.owner() == vm.addr(key), "sender is not ProxyAdmin owner");

        vm.startBroadcast(key);
        implementation = new TripFundV2();
        admin.upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(implementation), "");
        vm.stopBroadcast();

        fund = TripFundV2(proxy);
    }
}
