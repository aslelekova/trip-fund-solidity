pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {FundBehaviorTest} from "./TripFund.t.sol";

abstract contract ProxyFundBehaviorTest is FundBehaviorTest {
    address internal implementation;
    address internal constant ADMIN_OWNER = address(0xAD);

    function _newImplementation() internal virtual returns (address);

    function setUp() public override {
        implementation = _newImplementation();
        super.setUp();
    }

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFund)
    {
        return TripFund(
            address(
                new TransparentUpgradeableProxy(
                    implementation,
                    ADMIN_OWNER,
                    abi.encodeCall(TripFundV1.initialize, (token_, organizer_, goal_, deadline_))
                )
            )
        );
    }

    function testImplementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TripFundV1(implementation).initialize(address(token), ORGANIZER, GOAL, end);
    }

    function testProxyCannotBeInitializedAgain() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TripFundV1(address(fund)).initialize(address(token), ORGANIZER, GOAL, end);
        assertEq(fund.organizer(), ORGANIZER);
    }
}

contract TripFundV1Test is ProxyFundBehaviorTest {
    function _newImplementation() internal override returns (address) {
        return address(new TripFundV1());
    }
}

contract TripFundV2Test is ProxyFundBehaviorTest {
    function _newImplementation() internal override returns (address) {
        return address(new TripFundV2());
    }

    function testContributeForCreditsBeneficiaryAndChargesPayer() public {
        TripFundV2 upgraded = TripFundV2(address(fund));
        _contribute(BOB, 5 ether);
        vm.prank(ALICE);
        upgraded.contributeFor(BOB, 20 ether);
        vm.prank(ALICE);
        upgraded.contributeFor(BOB, 10 ether);
        _assertAccounting(0, 35 ether, 35 ether, 35 ether);
        assertEq(token.balanceOf(ALICE), 970 ether);
        assertEq(token.balanceOf(BOB), 995 ether);
        vm.warp(end);
        vm.prank(ALICE);
        vm.expectRevert(errorSelector("NoContribution()"));
        upgraded.refund();
        vm.prank(BOB);
        upgraded.refund();
        assertEq(token.balanceOf(BOB), 1_030 ether);
        assertEq(token.balanceOf(ALICE), 970 ether);
        _assertAccounting(0, 0, 35 ether, 0);
    }

    function testContributeForRejectsZeroBeneficiary() public {
        vm.prank(ALICE);
        vm.expectRevert(errorSelector("ZeroAddress()"));
        TripFundV2(address(fund)).contributeFor(address(0), 10 ether);
        _assertAccounting(0, 0, 0, 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
    }

    function testContributeForRejectsZeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(errorSelector("ZeroAmount()"));
        TripFundV2(address(fund)).contributeFor(BOB, 0);
        _assertAccounting(0, 0, 0, 0);
    }

    function testContributeForUsesPayerAllowance() public {
        vm.prank(ALICE);
        token.approve(address(fund), 0);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                errorSelector("ERC20InsufficientAllowance(address,uint256,uint256)"),
                address(fund),
                0,
                10 ether
            )
        );
        TripFundV2(address(fund)).contributeFor(BOB, 10 ether);
        _assertAccounting(0, 0, 0, 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
    }

    function testContributeForUsesPayerBalance() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, INITIAL_BALANCE));
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                errorSelector("ERC20InsufficientBalance(address,uint256,uint256)"), ALICE, 0, 10 ether
            )
        );
        TripFundV2(address(fund)).contributeFor(BOB, 10 ether);
        _assertAccounting(0, 0, 0, 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 2_000 ether);
    }

    function testContributeForOneSecondBeforeDeadline() public {
        vm.warp(end - 1);
        vm.prank(ALICE);
        TripFundV2(address(fund)).contributeFor(BOB, 10 ether);
        _assertAccounting(0, 10 ether, 10 ether, 10 ether);
    }

    function testContributeForAtDeadlineReverts() public {
        vm.warp(end);
        vm.prank(ALICE);
        vm.expectRevert(errorSelector("FundingClosed()"));
        TripFundV2(address(fund)).contributeFor(BOB, 10 ether);
        _assertAccounting(0, 0, 0, 0);
    }

    function testContributeForEvent() public {
        vm.expectEmit(true, true, false, true, address(fund));
        emit Contribution(ALICE, BOB, 10 ether);
        vm.prank(ALICE);
        TripFundV2(address(fund)).contributeFor(BOB, 10 ether);
    }

    function testContributeForCanPayForSelf() public {
        vm.prank(ALICE);
        TripFundV2(address(fund)).contributeFor(ALICE, 10 ether);
        _assertAccounting(10 ether, 0, 10 ether, 10 ether);
    }
}
