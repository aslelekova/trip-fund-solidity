pragma solidity 0.8.24;

import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MockToken} from "../src/MockToken.sol";
import {TripFundCore} from "../src/TripFundCore.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV1} from "../src/TripFundV1.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {TestBase} from "./TestBase.sol";

contract ObservingToken is MockToken {
    TripFundCore public fund;
    address public beneficiary;
    uint256 public mode;
    uint256 public expectedContribution;
    uint256 public expectedRaised;
    bool public observed;

    function observe(
        TripFundCore fund_,
        address beneficiary_,
        uint256 mode_,
        uint256 contribution_,
        uint256 raised_
    ) external {
        fund = fund_;
        beneficiary = beneficiary_;
        mode = mode_;
        expectedContribution = contribution_;
        expectedRaised = raised_;
        observed = false;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (msg.sender == address(fund)) _inspect();
        return super.transferFrom(from, to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (msg.sender == address(fund)) _inspect();
        return super.transfer(to, amount);
    }

    function _inspect() internal {
        require(fund.contributions(beneficiary) == expectedContribution, "contribution not updated first");
        require(fund.totalRaised() == expectedRaised, "total not updated first");
        if (mode == 3) require(fund.withdrawn(), "withdrawal not marked first");
        bytes memory data;
        if (mode == 1) data = abi.encodeCall(TripFundCore.contribute, (1));
        else if (mode == 2) data = abi.encodeCall(TripFundCore.refund, ());
        else if (mode == 3) data = abi.encodeCall(TripFundCore.withdraw, ());
        else data = abi.encodeCall(TripFundV2.contributeFor, (beneficiary, 1));
        (bool success, bytes memory result) = address(fund).call(data);
        require(!success, "reentrant call succeeded");
        require(
            keccak256(result) == keccak256(abi.encodeWithSelector(TripFundCore.ReentrantCall.selector)),
            "unexpected reentrancy error"
        );
        observed = true;
    }
}

contract TripFundSecurityTest is TestBase {
    ObservingToken internal token;
    TripFund internal fund;
    address internal constant ALICE = address(0xA11CE);
    address internal constant ORGANIZER = address(0xCAFE);
    uint256 internal end;

    function setUp() public {
        vm.warp(1_800_000_000);
        end = block.timestamp + 1 days;
        token = new ObservingToken();
        fund = new TripFund(address(token), ORGANIZER, 100 ether, end);
        token.mint(ALICE, 1_000 ether);
        vm.prank(ALICE);
        token.approve(address(fund), type(uint256).max);
    }

    function testContributionUpdatesStateBeforeTransferAndBlocksReentrancy() public {
        token.observe(fund, ALICE, 1, 20 ether, 20 ether);
        vm.prank(ALICE);
        fund.contribute(20 ether);
        assertTrue(token.observed());
        assertEq(token.balanceOf(address(fund)), 20 ether);
        assertEq(fund.totalRaised(), 20 ether);
    }

    function testRefundClearsContributionBeforeTransferAndBlocksReentrancy() public {
        vm.prank(ALICE);
        fund.contribute(20 ether);
        token.observe(fund, ALICE, 2, 0, 20 ether);
        vm.warp(end);
        vm.prank(ALICE);
        fund.refund();
        assertTrue(token.observed());
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(fund.totalRaised(), 20 ether);
    }

    function testWithdrawalMarksPaymentBeforeTransferAndBlocksReentrancy() public {
        vm.prank(ALICE);
        fund.contribute(100 ether);
        token.observe(fund, ALICE, 3, 100 ether, 100 ether);
        vm.warp(end);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertTrue(token.observed());
        assertEq(token.balanceOf(ORGANIZER), 100 ether);
        assertEq(fund.totalRaised(), 100 ether);
    }

    function testGiftUpdatesBeneficiaryBeforeTransferAndBlocksReentrancy() public {
        TripFundV2 implementation = new TripFundV2();
        TripFundV2 proxy = TripFundV2(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(TripFundV1.initialize, (address(token), ORGANIZER, 100 ether, end))
                )
            )
        );
        vm.prank(ALICE);
        token.approve(address(proxy), 20 ether);
        token.observe(proxy, ORGANIZER, 4, 20 ether, 20 ether);
        vm.prank(ALICE);
        proxy.contributeFor(ORGANIZER, 20 ether);
        assertTrue(token.observed());
        assertEq(proxy.contributions(ALICE), 0);
        assertEq(proxy.contributions(ORGANIZER), 20 ether);
        assertEq(token.balanceOf(ALICE), 980 ether);
    }
}
