pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract TripFundCore {
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public organizer;
    uint256 public goal;
    uint256 public deadline;
    uint256 public totalRaised;
    bool public withdrawn;
    mapping(address => uint256) public contributions;
    uint256 private _entered;

    error ZeroAddress();
    error ZeroGoal();
    error InvalidDeadline();
    error ZeroAmount();
    error FundingClosed();
    error FundingOpen();
    error Unauthorized();
    error GoalNotReached();
    error GoalReached();
    error AlreadyWithdrawn();
    error NoContribution();
    error ReentrantCall();

    event Contribution(address indexed payer, address indexed beneficiary, uint256 amount);
    event Refund(address indexed contributor, uint256 amount);
    event Withdrawal(address indexed organizer, uint256 amount);

    modifier nonReentrant() {
        if (_entered != 0) revert ReentrantCall();
        _entered = 1;
        _;
        _entered = 0;
    }

    function contribute(uint256 amount) external nonReentrant {
        _contribute(msg.sender, amount);
    }

    function withdraw() external nonReentrant {
        if (msg.sender != organizer) revert Unauthorized();
        if (block.timestamp < deadline) revert FundingOpen();
        if (totalRaised < goal) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        withdrawn = true;
        uint256 amount = totalRaised;
        token.safeTransfer(organizer, amount);
        emit Withdrawal(organizer, amount);
    }

    function refund() external nonReentrant {
        if (block.timestamp < deadline) revert FundingOpen();
        if (totalRaised >= goal) revert GoalReached();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NoContribution();

        contributions[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Refund(msg.sender, amount);
    }

    function _initializeFund(address token_, address organizer_, uint256 goal_, uint256 deadline_) internal {
        if (token_ == address(0) || organizer_ == address(0)) revert ZeroAddress();
        if (goal_ == 0) revert ZeroGoal();
        if (deadline_ <= block.timestamp) revert InvalidDeadline();

        token = IERC20(token_);
        organizer = organizer_;
        goal = goal_;
        deadline = deadline_;
    }

    function _contribute(address beneficiary, uint256 amount) internal {
        if (block.timestamp >= deadline) revert FundingClosed();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        contributions[beneficiary] += amount;
        totalRaised += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Contribution(msg.sender, beneficiary, amount);
    }
}
