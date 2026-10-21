pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TripFund} from "../src/TripFund.sol";
import {MockToken} from "../src/MockToken.sol";
import {TestBase} from "./TestBase.sol";

abstract contract FundBehaviorTest is TestBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ORGANIZER = address(0xCAFE);
    uint256 internal constant GOAL = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint256 internal end;
    MockToken internal token;
    TripFund internal fund;

    event Contribution(address indexed payer, address indexed beneficiary, uint256 amount);
    event Refund(address indexed contributor, uint256 amount);
    event Withdrawal(address indexed organizer, uint256 amount);

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        virtual
        returns (TripFund);

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        end = block.timestamp + 7 days;
        token = new MockToken();
        fund = _deploy(address(token), ORGANIZER, GOAL, end);
        token.mint(ALICE, INITIAL_BALANCE);
        token.mint(BOB, INITIAL_BALANCE);
        vm.prank(ALICE);
        token.approve(address(fund), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(fund), type(uint256).max);
    }

    function _contribute(address payer, uint256 amount) internal {
        vm.prank(payer);
        fund.contribute(amount);
    }

    function _assertAccounting(uint256 alice, uint256 bob, uint256 total, uint256 held) internal view {
        assertEq(fund.contributions(ALICE), alice);
        assertEq(fund.contributions(BOB), bob);
        assertEq(fund.totalRaised(), total);
        assertEq(token.balanceOf(address(fund)), held);
    }

    function testParameters() public view {
        assertEq(address(fund.token()), address(token));
        assertEq(fund.organizer(), ORGANIZER);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), end);
        assertTrue(!fund.withdrawn());
        _assertAccounting(0, 0, 0, 0);
    }

    function testRejectZeroToken() public {
        vm.expectRevert(errorSelector("ZeroAddress()"));
        _deploy(address(0), ORGANIZER, GOAL, end);
    }

    function testRejectZeroOrganizer() public {
        vm.expectRevert(errorSelector("ZeroAddress()"));
        _deploy(address(token), address(0), GOAL, end);
    }

    function testRejectZeroGoal() public {
        vm.expectRevert(errorSelector("ZeroGoal()"));
        _deploy(address(token), ORGANIZER, 0, end);
    }

    function testRejectDeadlineNow() public {
        vm.expectRevert(errorSelector("InvalidDeadline()"));
        _deploy(address(token), ORGANIZER, GOAL, block.timestamp);
    }

    function testRejectDeadlinePast() public {
        vm.expectRevert(errorSelector("InvalidDeadline()"));
        _deploy(address(token), ORGANIZER, GOAL, block.timestamp - 1);
    }

    function testTwoContributorsAndRepeatedContribution() public {
        _contribute(ALICE, 20 ether);
        _contribute(BOB, 30 ether);
        _contribute(ALICE, 15 ether);
        _assertAccounting(35 ether, 30 ether, 65 ether, 65 ether);
        assertEq(token.balanceOf(ALICE), 965 ether);
        assertEq(token.balanceOf(BOB), 970 ether);
    }

    function testZeroContributionRevertsWithoutChanges() public {
        vm.expectRevert(errorSelector("ZeroAmount()"));
        _contribute(ALICE, 0);
        _assertAccounting(0, 0, 0, 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
    }

    function testInsufficientAllowanceRollsBack() public {
        _contribute(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(address(fund), 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 2 ether, 3 ether
            )
        );
        _contribute(ALICE, 3 ether);
        _assertAccounting(10 ether, 0, 10 ether, 10 ether);
        assertEq(token.balanceOf(ALICE), 990 ether);
        assertEq(token.allowance(ALICE, address(fund)), 2 ether);
    }

    function testInsufficientBalanceRollsBack() public {
        vm.prank(ALICE);
        token.approve(address(fund), 2_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, INITIAL_BALANCE, 1_001 ether
            )
        );
        _contribute(ALICE, 1_001 ether);
        _assertAccounting(0, 0, 0, 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.allowance(ALICE, address(fund)), 2_000 ether);
    }

    function testContributionOneSecondBeforeDeadline() public {
        vm.warp(end - 1);
        _contribute(ALICE, 1 ether);
        _assertAccounting(1 ether, 0, 1 ether, 1 ether);
    }

    function testContributionAtDeadlineReverts() public {
        vm.warp(end);
        vm.expectRevert(errorSelector("FundingClosed()"));
        _contribute(ALICE, 1 ether);
        _assertAccounting(0, 0, 0, 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
    }

    function testContributionAfterDeadlineReverts() public {
        vm.warp(end + 1);
        vm.expectRevert(errorSelector("FundingClosed()"));
        _contribute(ALICE, 1 ether);
    }

    function testWithdrawBeforeDeadlineEvenWhenGoalReached() public {
        _contribute(ALICE, GOAL);
        vm.warp(end - 1);
        vm.prank(ORGANIZER);
        vm.expectRevert(errorSelector("FundingOpen()"));
        fund.withdraw();
        assertTrue(!fund.withdrawn());
        assertEq(token.balanceOf(ORGANIZER), 0);
    }

    function testRefundBeforeDeadlineOnFailure() public {
        _contribute(ALICE, 1 ether);
        vm.warp(end - 1);
        vm.prank(ALICE);
        vm.expectRevert(errorSelector("FundingOpen()"));
        fund.refund();
        _assertAccounting(1 ether, 0, 1 ether, 1 ether);
    }

    function testRefundBeforeDeadlineOnSuccess() public {
        _contribute(ALICE, GOAL);
        vm.prank(ALICE);
        vm.expectRevert(errorSelector("FundingOpen()"));
        fund.refund();
    }

    function testWithdrawExactlyGoalAtDeadline() public {
        _contribute(ALICE, 40 ether);
        _contribute(BOB, 60 ether);
        vm.warp(end);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        _assertAccounting(40 ether, 60 ether, GOAL, 0);
        assertTrue(fund.withdrawn());
    }

    function testWithdrawAboveGoal() public {
        _contribute(ALICE, 150 ether);
        vm.warp(end);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), 150 ether);
        _assertAccounting(150 ether, 0, 150 ether, 0);
    }

    function testOutsiderCannotWithdraw() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.prank(BOB);
        vm.expectRevert(errorSelector("Unauthorized()"));
        fund.withdraw();
        _assertAccounting(GOAL, 0, GOAL, GOAL);
        assertTrue(!fund.withdrawn());
    }

    function testCannotWithdrawTwice() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.startPrank(ORGANIZER);
        fund.withdraw();
        vm.expectRevert(errorSelector("AlreadyWithdrawn()"));
        fund.withdraw();
        vm.stopPrank();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(fund.totalRaised(), GOAL);
    }

    function testCannotWithdrawFailedCampaign() public {
        _contribute(ALICE, GOAL - 1);
        vm.warp(end);
        vm.prank(ORGANIZER);
        vm.expectRevert(errorSelector("GoalNotReached()"));
        fund.withdraw();
        assertTrue(!fund.withdrawn());
    }

    function testIndependentRefundsKeepTotalRaised() public {
        _contribute(ALICE, 20 ether);
        _contribute(ALICE, 10 ether);
        _contribute(BOB, 40 ether);
        vm.warp(end);
        vm.prank(ALICE);
        fund.refund();
        _assertAccounting(0, 40 ether, 70 ether, 40 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), 960 ether);
        vm.prank(BOB);
        fund.refund();
        _assertAccounting(0, 0, 70 ether, 0);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
    }

    function testCannotRefundTwice() public {
        _contribute(ALICE, 10 ether);
        vm.warp(end);
        vm.startPrank(ALICE);
        fund.refund();
        vm.expectRevert(errorSelector("NoContribution()"));
        fund.refund();
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function testCannotRefundWithoutContribution() public {
        _contribute(ALICE, 10 ether);
        vm.warp(end);
        vm.prank(BOB);
        vm.expectRevert(errorSelector("NoContribution()"));
        fund.refund();
        _assertAccounting(10 ether, 0, 10 ether, 10 ether);
    }

    function testCannotRefundSuccessfulCampaignBeforeWithdrawal() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.prank(ALICE);
        vm.expectRevert(errorSelector("GoalReached()"));
        fund.refund();
        _assertAccounting(GOAL, 0, GOAL, GOAL);
    }

    function testCannotRefundSuccessfulCampaignAfterWithdrawal() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.prank(ORGANIZER);
        fund.withdraw();
        vm.prank(ALICE);
        vm.expectRevert(errorSelector("GoalReached()"));
        fund.refund();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
    }

    function testDirectTransferRemainsAfterWithdrawal() public {
        _contribute(ALICE, GOAL);
        vm.prank(BOB);
        assertTrue(token.transfer(address(fund), 17 ether));
        _assertAccounting(GOAL, 0, GOAL, 117 ether);
        vm.warp(end);
        vm.prank(ORGANIZER);
        fund.withdraw();
        _assertAccounting(GOAL, 0, GOAL, 17 ether);
        assertEq(token.balanceOf(ORGANIZER), GOAL);
    }

    function testDirectTransferCannotTurnFailureIntoSuccessAndRemainsAfterRefunds() public {
        _contribute(ALICE, 10 ether);
        _contribute(BOB, 20 ether);
        vm.prank(BOB);
        assertTrue(token.transfer(address(fund), 200 ether));
        _assertAccounting(10 ether, 20 ether, 30 ether, 230 ether);
        vm.warp(end);
        vm.prank(ORGANIZER);
        vm.expectRevert(errorSelector("GoalNotReached()"));
        fund.withdraw();
        vm.prank(ALICE);
        fund.refund();
        vm.prank(BOB);
        fund.refund();
        _assertAccounting(0, 0, 30 ether, 200 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), 800 ether);
    }

    function testContributionEvent() public {
        vm.expectEmit(true, true, false, true, address(fund));
        emit Contribution(ALICE, ALICE, 15 ether);
        _contribute(ALICE, 15 ether);
    }

    function testRefundEvent() public {
        _contribute(ALICE, 15 ether);
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Refund(ALICE, 15 ether);
        vm.prank(ALICE);
        fund.refund();
    }

    function testWithdrawalEvent() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Withdrawal(ORGANIZER, GOAL);
        vm.prank(ORGANIZER);
        fund.withdraw();
    }

    function testFalseTransferFromRollsBackAccounting() public {
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        _contribute(ALICE, 10 ether);
        _assertAccounting(0, 0, 0, 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
    }

    function testWithdrawTransferFailureCanBeRetried() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(false));
        vm.prank(ORGANIZER);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        fund.withdraw();
        assertTrue(!fund.withdrawn());
        _assertAccounting(GOAL, 0, GOAL, GOAL);
        assertEq(token.balanceOf(ORGANIZER), 0);
        vm.clearMockedCalls();
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertTrue(fund.withdrawn());
    }

    function testRefundTransferFailureCanBeRetried() public {
        _contribute(ALICE, 10 ether);
        vm.warp(end);
        vm.mockCall(address(token), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(false));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        fund.refund();
        _assertAccounting(10 ether, 0, 10 ether, 10 ether);
        assertEq(token.balanceOf(ALICE), 990 ether);
        vm.clearMockedCalls();
        vm.prank(ALICE);
        fund.refund();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        _assertAccounting(0, 0, 10 ether, 0);
    }

    function testFuzzContributionsAndFinalSettlement(uint96 a, uint96 b) public {
        uint256 alice = uint256(a) % INITIAL_BALANCE + 1;
        uint256 bob = uint256(b) % INITIAL_BALANCE + 1;
        _contribute(ALICE, alice);
        _contribute(BOB, bob);
        uint256 raised = alice + bob;
        _assertAccounting(alice, bob, raised, raised);
        vm.warp(end);
        if (raised >= GOAL) {
            vm.prank(ORGANIZER);
            fund.withdraw();
            assertEq(token.balanceOf(ORGANIZER), raised);
        } else {
            vm.prank(BOB);
            fund.refund();
            vm.prank(ALICE);
            fund.refund();
            assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
            assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
        }
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), raised);
    }
}

contract TripFundTest is FundBehaviorTest {
    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        override
        returns (TripFund)
    {
        return new TripFund(token_, organizer_, goal_, deadline_);
    }
}
