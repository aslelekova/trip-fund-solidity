pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {MockToken} from "../src/MockToken.sol";
import {TestBase} from "./TestBase.sol";

contract TripFundUpgradeTest is TestBase {
    bytes32 internal constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 internal constant IMPLEMENTATION_SLOT =
        bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    address internal constant OWNER = address(0xAD);
    address internal constant ORGANIZER = address(0xCAFE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    MockToken internal token;
    TripFundV1 internal v1;
    TripFundV2 internal v2Implementation;
    ProxyAdmin internal admin;
    uint256 internal end;

    function setUp() public {
        vm.warp(1_800_000_000);
        end = block.timestamp + 7 days;
        token = new MockToken();
        TripFundV1 implementation = new TripFundV1();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            OWNER,
            abi.encodeCall(TripFundV1.initialize, (address(token), ORGANIZER, 100 ether, end))
        );
        v1 = TripFundV1(address(proxy));
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), ADMIN_SLOT)))));
        v2Implementation = new TripFundV2();
        token.mint(ALICE, 1_000 ether);
        token.mint(BOB, 1_000 ether);
        vm.prank(ALICE);
        token.approve(address(proxy), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(proxy), type(uint256).max);
    }

    function _upgrade() internal returns (TripFundV2) {
        vm.prank(OWNER);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(v1)), address(v2Implementation), "");
        return TripFundV2(address(v1));
    }

    function testV1ContributionUpgradeGiftAndRefund() public {
        vm.prank(ALICE);
        v1.contribute(20 ether);
        vm.prank(BOB);
        v1.contribute(30 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(address(v1), 7 ether));
        address proxyAddress = address(v1);
        vm.warp(end - 1 days);
        TripFundV2 v2 = _upgrade();
        assertEq(address(v2), proxyAddress);
        assertEq(address(v2.token()), address(token));
        assertEq(v2.organizer(), ORGANIZER);
        assertEq(v2.goal(), 100 ether);
        assertEq(v2.deadline(), end);
        assertEq(v2.contributions(ALICE), 20 ether);
        assertEq(v2.contributions(BOB), 30 ether);
        assertEq(v2.totalRaised(), 50 ether);
        assertEq(token.balanceOf(proxyAddress), 57 ether);
        assertTrue(!v2.withdrawn());
        assertEq(token.allowance(ALICE, proxyAddress), type(uint256).max);
        assertEq(
            address(uint160(uint256(vm.load(proxyAddress, IMPLEMENTATION_SLOT)))), address(v2Implementation)
        );
        assertEq(address(uint160(uint256(vm.load(proxyAddress, ADMIN_SLOT)))), address(admin));
        assertEq(admin.owner(), OWNER);
        vm.prank(ALICE);
        v2.contributeFor(BOB, 15 ether);
        vm.prank(BOB);
        v2.contribute(5 ether);
        assertEq(v2.contributions(ALICE), 20 ether);
        assertEq(v2.contributions(BOB), 50 ether);
        assertEq(v2.totalRaised(), 70 ether);
        assertEq(token.balanceOf(proxyAddress), 77 ether);
        vm.warp(end);
        vm.prank(BOB);
        v2.refund();
        assertEq(token.balanceOf(BOB), 1_015 ether);
        assertEq(v2.contributions(BOB), 0);
        assertEq(v2.contributions(ALICE), 20 ether);
        vm.prank(ALICE);
        v2.refund();
        assertEq(token.balanceOf(ALICE), 978 ether);
        assertEq(v2.totalRaised(), 70 ether);
        assertEq(token.balanceOf(proxyAddress), 7 ether);
    }

    function testOnlyProxyAdminOwnerCanUpgrade() public {
        bytes32 oldImplementation = vm.load(address(v1), IMPLEMENTATION_SLOT);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(errorSelector("OwnableUnauthorizedAccount(address)"), ALICE));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(v1)), address(v2Implementation), "");
        assertTrue(vm.load(address(v1), IMPLEMENTATION_SLOT) == oldImplementation);
        assertEq(admin.owner(), OWNER);
    }

    function testOrganizerCannotUpgradeUnlessAdminOwner() public {
        vm.prank(ORGANIZER);
        vm.expectRevert(
            abi.encodeWithSelector(errorSelector("OwnableUnauthorizedAccount(address)"), ORGANIZER)
        );
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(v1)), address(v2Implementation), "");
    }

    function testCannotBypassProxyAdmin() public {
        vm.prank(ALICE);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(v1)).upgradeToAndCall(address(v2Implementation), "");
    }

    function testUpgradeDoesNotPermitReinitialization() public {
        TripFundV2 v2 = _upgrade();
        vm.prank(ALICE);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize(address(token), ALICE, 1, end + 1 days);
        assertEq(v2.organizer(), ORGANIZER);
        assertEq(v2.goal(), 100 ether);
        assertEq(v2.deadline(), end);
    }

    function testV1AndV2ImplementationsAreLocked() public {
        TripFundV1 implementation = new TripFundV1();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(token), ORGANIZER, 100 ether, end);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2Implementation.initialize(address(token), ORGANIZER, 100 ether, end);
    }
}
