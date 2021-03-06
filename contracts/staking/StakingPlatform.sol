// SPDX-License-Identifier: MIT
pragma solidity =0.8.9;

import "./IStakingPlatform.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @author RetreebInc
/// @title Staking Platform with fixed APY and lockup
contract StakingPlatform is IStakingPlatform, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;

    uint8 public immutable fixedAPY;

    uint public immutable stakingDuration;
    uint public immutable lockupDuration;
    uint public immutable stakingMax;

    uint public startPeriod;
    uint public lockupPeriod;
    uint public endPeriod;

    uint private totalStaked;
    uint internal precision = 1E6;

    mapping(address => uint) public staked;
    mapping(address => uint) public stakeRewardsToClaim;
    mapping(address => uint) public claimedRewards;

    /**
     * @notice constructor contains all the parameters of the staking platform
     * @dev all parameters are immutable
     */
    constructor(
        address _token,
        uint8 _fixedAPY,
        uint _durationInDays,
        uint _lockDurationInDays,
        uint _maxAmountStaked
    ) {
        stakingDuration = _durationInDays * 1 days;
        lockupDuration = _lockDurationInDays * 1 days;
        token = IERC20(_token);
        fixedAPY = _fixedAPY;
        stakingMax = _maxAmountStaked;
    }

    /**
     * @notice function that start the staking
     * @dev set `startPeriod` to the current current `block.timestamp`
     * as well as the `endPeriod` which is `startPeriod` + `stakingDuration`
     */
    function startStaking() external override onlyOwner {
        require(startPeriod == 0, "Staking has already started");
        startPeriod = block.timestamp;
        lockupPeriod = block.timestamp + lockupDuration;
        endPeriod = block.timestamp + stakingDuration;
        emit StartStaking(startPeriod, endPeriod);
    }

    /**
     * @notice function that allows a user to deposit tokens
     * @dev user must first approve the amount to deposit before calling this function,
     * cannot exceed the `maxAmountStaked`
     * @param amount, the amount to be deposited
     */
    function deposit(uint amount) external override {
        require(
            endPeriod == 0 || endPeriod > block.timestamp,
            "Staking period ended"
        );
        require(
            totalStaked + amount <= stakingMax,
            "Amount staked exceeds MaxStake"
        );
        stakeRewardsToClaim[msg.sender] = _calculateRewards(msg.sender);
        if (stakeRewardsToClaim[msg.sender] > 0) {
            claimRewards();
        }
        token.safeTransferFrom(msg.sender, address(this), amount);
        staked[msg.sender] += amount;
        totalStaked += amount;
        emit Deposit(msg.sender, amount);
    }

    /**
     * @notice function that allows a user to withdraw its initial deposit
     * @dev must be called only when `block.timestamp` >= `endPeriod`
     */
    function withdraw() external override {
        require(
            block.timestamp >= lockupPeriod,
            "No withdraw until lockup ends"
        );
        stakeRewardsToClaim[msg.sender] = _calculateRewards(msg.sender);
        if (stakeRewardsToClaim[msg.sender] > 0) {
            claimRewards();
        }
        totalStaked -= staked[msg.sender];
        uint stakedBalance = staked[msg.sender];
        staked[msg.sender] = 0;
        token.safeTransfer(msg.sender, stakedBalance);
        emit Withdraw(msg.sender, stakedBalance);
    }

    /**
     * @notice claim all remaining balance on the contract
     * Residual balance is all the remaining tokens that have not been distributed
     * (e.g, in case the number of stakeholders is not sufficient)
     * @dev Can only be called one year after the end of the staking period
     */
    function withdrawResidualBalance() external onlyOwner {
        require(
            block.timestamp >= endPeriod + (365 * 1 days),
            "Withdraw 1year after endPeriod"
        );

        uint balance = token.balanceOf(address(this));
        uint residualBalance = balance - (totalStaked);
        require(residualBalance > 0, "No residual Balance to withdraw");
        token.safeTransfer(owner(), residualBalance);
    }

    /**
     * @notice function that returns the amount of total Staked tokens
     * for a specific user
     * @return uint amount of the total deposited Tokens by the caller
     */
    function amountStaked() external view override returns (uint) {
        return staked[msg.sender];
    }

    /**
     * @notice function that returns the amount of total Staked tokens
     * on the smart contract
     * @return uint amount of the total deposited Tokens
     */
    function totalDeposited() external view override returns (uint) {
        return totalStaked;
    }

    /**
     * @notice function that returns the amount of pending rewards
     * that can be claimed by the user
     * @param stakeHolder, address of the user to be checked
     * @return uint amount of claimable tokens by the caller
     */
    function rewardOf(address stakeHolder)
        external
        view
        override
        returns (uint)
    {
        return _calculateRewards(stakeHolder);
    }

    /**
     * @notice function that claims pending rewards
     * @dev transfer the pending rewards to the user address
     */
    function claimRewards() public override {
        stakeRewardsToClaim[msg.sender] = _calculateRewards(msg.sender);
        require(stakeRewardsToClaim[msg.sender] > 0, "Nothing to claim");
        claimedRewards[msg.sender] += _calculateRewards(msg.sender);
        uint stakedRewards = stakeRewardsToClaim[msg.sender];
        stakeRewardsToClaim[msg.sender] = 0;
        token.safeTransfer(msg.sender, stakedRewards);
        emit Claim(msg.sender, stakedRewards);
    }

    /**
     * @notice calculate rewards based on the `fixedAPY`, `_percentageTimeRemaining()`
     * @dev the higher is the precision and the more the time remaining will be precise
     * @param stakeHolder, address of the user to be checked
     * @return uint amount of claimable tokens of the specified address
     */
    function _calculateRewards(address stakeHolder)
        internal
        view
        returns (uint)
    {
        if (startPeriod == 0 || staked[stakeHolder] == 0) {
            return 0;
        }
        return
            (((staked[stakeHolder] * fixedAPY) * _percentageTimeRemaining()) /
                (precision * 100)) - claimedRewards[stakeHolder];
    }

    /**
     * @notice function that returns the remaining time in seconds of the staking period
     * @dev the higher is the precision and the more the time remaining will be precise
     * @return uint percentage of time remaining * precision
     */
    function _percentageTimeRemaining() internal view returns (uint) {
        if (endPeriod > block.timestamp) {
            uint timeRemaining = endPeriod - block.timestamp;
            return
                (precision * (stakingDuration - timeRemaining)) /
                stakingDuration;
        }
        return (precision * stakingDuration) / stakingDuration;
    }
}
