// SPDX-License-Identifier: GPL-2.0-or-later
// see: https://github.com/Uniswap/v3-staker/blob/4328b957701de8bed83689aa22c32eda7928d5ab/contracts/UniswapV3Staker.sol
// slightly modified from uniswap
// Search "NEW" for all changes

pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-staker/contracts/interfaces/IUniswapV3Staker.sol';
import '@uniswap/v3-staker/contracts/libraries/IncentiveId.sol';
import '@uniswap/v3-staker/contracts/libraries/RewardMath.sol';
import '@uniswap/v3-staker/contracts/libraries/NFTPositionInfo.sol';
import '@uniswap/v3-staker/contracts/libraries/TransferHelperExtended.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';

// NEW: contract is ownable to allow for extra functionality
import '@openzeppelin/contracts/access/Ownable.sol';

/// @title Extended Uniswap V3 staking interface
contract V3StakerExtended is IUniswapV3Staker, Multicall, Ownable {
    uint128 constant MAX_UINT_128 = type(uint128).max;

    /// @notice Represents a staking incentive
    struct Incentive {
        uint256 totalRewardUnclaimed;
        uint160 totalSecondsClaimedX128;
        uint96 numberOfStakes;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint160 secondsPerLiquidityInsideInitialX128;
        uint96 liquidityNoOverflow;
        uint128 liquidityIfOverflow;
    }

    /// @inheritdoc IUniswapV3Staker
    IUniswapV3Factory public immutable override factory;
    /// @inheritdoc IUniswapV3Staker
    INonfungiblePositionManager public immutable override nonfungiblePositionManager;

    /// @inheritdoc IUniswapV3Staker
    uint256 public immutable override maxIncentiveStartLeadTime;
    /// @inheritdoc IUniswapV3Staker
    uint256 public immutable override maxIncentiveDuration;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev stakes[tokenId][incentiveHash] => Stake
    mapping(uint256 => mapping(bytes32 => Stake)) private _stakes;

    // NEW: used for enumerating user deposits
    mapping(address => mapping(uint256 => uint256)) private _userDeposits;
    mapping(address => uint256) public numDeposits;
    mapping(uint256 => uint256) private _userDepositsIndex;

    // IWETH9 public immutable WETH9 = IWETH9(0xc778417E063141139Fce010982780140Aa0cD5Ab); //rinkeby
    IWETH9 public immutable WETH9 = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); //mainnet

    function userDeposits(address user, uint256 index) public view returns (uint256 tokenId) {
        require(index < numDeposits[user], 'UniswapV3StakerExtended: index OOB');
        return _userDeposits[user][index];
    }

    // NEW: used for tracking an incentives total liquidity
    mapping(bytes32 => uint256) public incentiveLiquidity;

    /// @inheritdoc IUniswapV3Staker
    function stakes(uint256 tokenId, bytes32 incentiveId)
        public
        view
        override
        returns (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity)
    {
        Stake storage stake = _stakes[tokenId][incentiveId];
        secondsPerLiquidityInsideInitialX128 = stake.secondsPerLiquidityInsideInitialX128;
        liquidity = stake.liquidityNoOverflow;
        if (liquidity == type(uint96).max) {
            liquidity = stake.liquidityIfOverflow;
        }
    }

    /// @dev rewards[rewardToken][owner] => uint256
    /// @inheritdoc IUniswapV3Staker
    mapping(IERC20Minimal => mapping(address => uint256)) public override rewards;

    // NEW: An incentive was altered
    event IncentiveAltered(bytes32 indexed incentiveId, uint256 change, bool increase);

    /// @param _factory the Uniswap V3 factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentiveDuration the max amount of seconds into the future the incentive startTime can be set
    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration
    ) {
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentiveDuration = _maxIncentiveDuration;
    }

    receive() external payable {
        require(
            msg.sender == address(nonfungiblePositionManager),
            'UniswapV3Staker::receive: Not WETH9'
        );
    }

    /// @inheritdoc IUniswapV3Staker
    function createIncentive(IncentiveKey memory key, uint256 reward) external override onlyOwner {
        require(reward > 0, 'UniswapV3Staker::createIncentive: reward must be positive');
        require(
            block.timestamp <= key.startTime,
            'UniswapV3Staker::createIncentive: start time must be now or in the future'
        );
        require(
            key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
            'UniswapV3Staker::createIncentive: start time too far into future'
        );
        require(
            key.startTime < key.endTime,
            'UniswapV3Staker::createIncentive: start time must be before end time'
        );
        require(
            key.endTime - key.startTime <= maxIncentiveDuration,
            'UniswapV3Staker::createIncentive: incentive duration is too long'
        );

        bytes32 incentiveId = IncentiveId.compute(key);

        incentives[incentiveId].totalRewardUnclaimed += reward;

        TransferHelperExtended.safeTransferFrom(
            address(key.rewardToken),
            msg.sender,
            address(this),
            reward
        );

        emit IncentiveCreated(
            key.rewardToken,
            key.pool,
            key.startTime,
            key.endTime,
            key.refundee,
            reward
        );
    }

    // TODO: test
    // NEW: Alter the unclaimed rewards in an incentive
    /// @dev Warning: this will alter unclaimed stakes by the proportional percentage you change
    /// totalRewardUnclaimed
    function alterIncentive(
        IncentiveKey memory key,
        uint256 change,
        bool increase
    ) external onlyOwner {
        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        if (increase)
            TransferHelperExtended.safeTransferFrom(
                address(key.rewardToken),
                msg.sender,
                address(this),
                change
            );

        uint256 unclaimed = incentive.totalRewardUnclaimed;
        if (!increase) {
            require(unclaimed > change, 'UniswapV3Staker::alterIncentive: too much');
            incentive.totalRewardUnclaimed -= change;
        } else incentive.totalRewardUnclaimed += change;

        if (!increase)
            TransferHelperExtended.safeTransfer(address(key.rewardToken), key.refundee, change);

        emit IncentiveAltered(incentiveId, change, increase);
    }

    /// @inheritdoc IUniswapV3Staker
    function endIncentive(IncentiveKey memory key)
        external
        override
        onlyOwner
        returns (uint256 refund)
    {
        require(
            block.timestamp >= key.endTime,
            'UniswapV3Staker::endIncentive: cannot end incentive before end time'
        );

        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        refund = incentive.totalRewardUnclaimed;

        require(refund > 0, 'UniswapV3Staker::endIncentive: no refund available');
        require(
            incentive.numberOfStakes == 0,
            'UniswapV3Staker::endIncentive: cannot end incentive while deposits are staked'
        );

        // issue the refund
        incentive.totalRewardUnclaimed = 0;
        TransferHelperExtended.safeTransfer(address(key.rewardToken), key.refundee, refund);

        // note we never clear totalSecondsClaimedX128

        emit IncentiveEnded(incentiveId, refund);
    }

    /// @notice Upon receiving a Uniswap V3 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(
            msg.sender == address(nonfungiblePositionManager),
            'UniswapV3Staker::onERC721Received: not a univ3 nft'
        );

        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager
            .positions(tokenId);

        deposits[tokenId] = Deposit({
            owner: from,
            numberOfStakes: 0,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
        emit DepositTransferred(tokenId, address(0), from);

        // NEW: record new deposit
        _recordUserDeposit(from, tokenId);

        if (data.length > 0) {
            if (data.length == 160) {
                _stakeToken(abi.decode(data, (IncentiveKey)), tokenId);
            } else {
                IncentiveKey[] memory keys = abi.decode(data, (IncentiveKey[]));
                for (uint256 i = 0; i < keys.length; i++) {
                    _stakeToken(keys[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IUniswapV3Staker
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(0), 'UniswapV3Staker::transferDeposit: invalid transfer recipient');
        address owner = deposits[tokenId].owner;
        require(
            owner == msg.sender,
            'UniswapV3Staker::transferDeposit: can only be called by deposit owner'
        );

        // NEW: Remove user token data
        _deleteUserDeposit(msg.sender, tokenId);

        // NEW: Record new deposit
        _recordUserDeposit(to, tokenId);

        deposits[tokenId].owner = to;
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IUniswapV3Staker
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) external override {
        require(to != address(this), 'UniswapV3Staker::withdrawToken: cannot withdraw to staker');
        Deposit memory deposit = deposits[tokenId];
        require(
            deposit.numberOfStakes == 0,
            'UniswapV3Staker::withdrawToken: cannot withdraw token while staked'
        );
        require(
            deposit.owner == msg.sender,
            'UniswapV3Staker::withdrawToken: only owner can withdraw token'
        );

        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        // NEW: Remove user token data.
        _deleteUserDeposit(msg.sender, tokenId);

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    /// @inheritdoc IUniswapV3Staker
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        require(
            deposits[tokenId].owner == msg.sender,
            'UniswapV3Staker::stakeToken: only owner can stake token'
        );

        _stakeToken(key, tokenId);
    }

    /// @inheritdoc IUniswapV3Staker
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        _unstake(key, tokenId, msg.sender);
    }

    function _unstake(
        IncentiveKey memory key,
        uint256 tokenId,
        address sender
    ) internal {
        Deposit memory deposit = deposits[tokenId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        if (block.timestamp < key.endTime) {
            require(
                deposit.owner == sender,
                'UniswapV3Staker::unstakeToken: only owner can withdraw token before incentive end time'
            );
        }

        bytes32 incentiveId = IncentiveId.compute(key);

        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity) = stakes(
            tokenId,
            incentiveId
        );

        require(liquidity != 0, 'UniswapV3Staker::unstakeToken: stake does not exist');

        Incentive storage incentive = incentives[incentiveId];

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;

        (, uint160 secondsPerLiquidityInsideX128, ) = key.pool.snapshotCumulativesInside(
            deposit.tickLower,
            deposit.tickUpper
        );
        (uint256 reward, uint160 secondsInsideX128) = RewardMath.computeRewardAmount(
            incentive.totalRewardUnclaimed,
            incentive.totalSecondsClaimedX128,
            key.startTime,
            key.endTime,
            liquidity,
            secondsPerLiquidityInsideInitialX128,
            secondsPerLiquidityInsideX128,
            block.timestamp
        );

        // if this overflows, e.g. after 2^32-1 full liquidity seconds have been claimed,
        // reward rate will fall drastically so it's safe
        incentive.totalSecondsClaimedX128 += secondsInsideX128;
        // reward is never greater than total reward unclaimed
        incentive.totalRewardUnclaimed -= reward;
        // this only overflows if a token has a total supply greater than type(uint256).max
        rewards[key.rewardToken][deposit.owner] += reward;

        // NEW: record loss of incentive liquidity
        if (incentiveLiquidity[incentiveId] > liquidity) {
            incentiveLiquidity[incentiveId] -= liquidity;
        } else {
            incentiveLiquidity[incentiveId] = 0;
        }

        Stake storage stake = _stakes[tokenId][incentiveId];
        delete stake.secondsPerLiquidityInsideInitialX128;
        delete stake.liquidityNoOverflow;
        if (liquidity >= type(uint96).max) delete stake.liquidityIfOverflow;
        emit TokenUnstaked(tokenId, incentiveId);
    }

    /// @inheritdoc IUniswapV3Staker
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external override returns (uint256 reward) {
        reward = rewards[rewardToken][msg.sender];
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[rewardToken][msg.sender] -= reward;
        TransferHelperExtended.safeTransfer(address(rewardToken), to, reward);

        emit RewardClaimed(to, reward);
    }

    /// @inheritdoc IUniswapV3Staker
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId)
        external
        view
        override
        returns (uint256 reward, uint160 secondsInsideX128)
    {
        bytes32 incentiveId = IncentiveId.compute(key);

        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity) = stakes(
            tokenId,
            incentiveId
        );
        require(liquidity > 0, 'UniswapV3Staker::getRewardInfo: stake does not exist');

        Deposit memory deposit = deposits[tokenId];
        Incentive memory incentive = incentives[incentiveId];

        (, uint160 secondsPerLiquidityInsideX128, ) = key.pool.snapshotCumulativesInside(
            deposit.tickLower,
            deposit.tickUpper
        );

        (reward, secondsInsideX128) = RewardMath.computeRewardAmount(
            incentive.totalRewardUnclaimed,
            incentive.totalSecondsClaimedX128,
            key.startTime,
            key.endTime,
            liquidity,
            secondsPerLiquidityInsideInitialX128,
            secondsPerLiquidityInsideX128,
            block.timestamp
        );
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId) private {
        require(
            block.timestamp >= key.startTime,
            'UniswapV3Staker::stakeToken: incentive not started'
        );
        require(block.timestamp < key.endTime, 'UniswapV3Staker::stakeToken: incentive ended');

        bytes32 incentiveId = IncentiveId.compute(key);

        require(
            incentives[incentiveId].totalRewardUnclaimed > 0,
            'UniswapV3Staker::stakeToken: non-existent incentive'
        );
        require(
            _stakes[tokenId][incentiveId].liquidityNoOverflow == 0,
            'UniswapV3Staker::stakeToken: token already staked'
        );

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) = NFTPositionInfo
            .getPositionInfo(factory, nonfungiblePositionManager, tokenId);

        require(
            pool == key.pool,
            'UniswapV3Staker::stakeToken: token pool is not the incentive pool'
        );
        require(liquidity > 0, 'UniswapV3Staker::stakeToken: cannot stake token with 0 liquidity');

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(
            tickLower,
            tickUpper
        );

        if (liquidity >= type(uint96).max) {
            _stakes[tokenId][incentiveId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: type(uint96).max,
                liquidityIfOverflow: liquidity
            });
        } else {
            Stake storage stake = _stakes[tokenId][incentiveId];
            stake.secondsPerLiquidityInsideInitialX128 = secondsPerLiquidityInsideX128;
            stake.liquidityNoOverflow = uint96(liquidity);
        }

        // NEW: record increase in incentive liquidity
        incentiveLiquidity[incentiveId] += liquidity;

        emit TokenStaked(tokenId, incentiveId, liquidity);
    }

    // NEW: records a user deposit
    function _recordUserDeposit(address account, uint256 tokenId) internal {
        uint256 length = numDeposits[account];
        _userDeposits[account][length] = tokenId;
        _userDepositsIndex[tokenId] = length;
        numDeposits[account]++;
    }

    // NEW: deletes a user deposit
    function _deleteUserDeposit(address account, uint256 tokenId) internal {
        uint256 lastTokenIndex = numDeposits[account] - 1;
        uint256 tokenIndex = _userDepositsIndex[tokenId];
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _userDeposits[account][lastTokenIndex];
            _userDeposits[account][tokenIndex] = lastTokenId;
            _userDepositsIndex[lastTokenId] = tokenIndex;
        }
        numDeposits[account]--;
        delete _userDepositsIndex[tokenId];
        delete _userDeposits[account][lastTokenIndex];
    }

    // NEW: increase and decrease liquidity while staking
    // TODO: this code is nasty
    function increaseLiquidity(
        IncentiveKey memory key,
        INonfungiblePositionManager.IncreaseLiquidityParams calldata params
    )
        external
        payable
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        _unstake(key, params.tokenId, msg.sender);
        (, , address token0, address token1, , , , , , , , ) = nonfungiblePositionManager.positions(
            params.tokenId
        );

        bool eth0 = token0 == address(WETH9) && msg.value > 0;
        bool eth1 = token1 == address(WETH9) && msg.value > 0;

        // collect necessary tokens
        if (eth0)
            require(msg.value >= params.amount0Desired, 'UniswapV3Staker: Not enough ETH sent');
        else
            TransferHelper.safeTransferFrom(
                token0,
                msg.sender,
                address(this),
                params.amount0Desired
            );

        if (eth1)
            require(msg.value >= params.amount1Desired, 'UniswapV3Staker: Not enough ETH sent');
        else
            TransferHelper.safeTransferFrom(
                token1,
                msg.sender,
                address(this),
                params.amount1Desired
            );

        _checkAllowance(token0, token1);

        (uint256 out0, uint256 out1) = (0, 0);
        {
            uint256 init0 = eth0 ? address(this).balance : IERC20(token0).balanceOf(address(this));
            uint256 init1 = eth1 ? address(this).balance : IERC20(token1).balanceOf(address(this));

            // increase liq
            (liquidity, amount0, amount1) = nonfungiblePositionManager.increaseLiquidity{
                value: msg.value
            }(params);

            nonfungiblePositionManager.refundETH();

            _stakeToken(key, params.tokenId);

            out0 = init0 - (eth0 ? address(this).balance : IERC20(token0).balanceOf(address(this)));
            out1 = init1 - (eth1 ? address(this).balance : IERC20(token1).balanceOf(address(this)));
        }
        // refund - we sent params.amountDesired
        if (eth0) TransferHelper.safeTransferETH(msg.sender, msg.value - out0);
        else if (params.amount0Desired > out0) {
            TransferHelper.safeTransfer(token0, msg.sender, params.amount0Desired - out0);
        }

        if (eth1) TransferHelper.safeTransferETH(msg.sender, msg.value - out1);
        else if (params.amount1Desired > out1) {
            TransferHelper.safeTransfer(token1, msg.sender, params.amount1Desired - out1);
        }
    }

    function decreaseLiquidity(
        IncentiveKey memory key,
        INonfungiblePositionManager.DecreaseLiquidityParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1) {
        _unstake(key, params.tokenId, msg.sender);

        (, , address token0, address token1, , , , , , , , ) = nonfungiblePositionManager.positions(
            params.tokenId
        );

        (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(params);

        // Will not let you decrease the entire amount of liquidity, should just withdraw for that
        // checks that position liquidity != 0

        (uint256 collect0, uint256 collect1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                params.tokenId,
                address(0),
                MAX_UINT_128,
                MAX_UINT_128
            )
        );

        if (token0 == address(WETH9)) nonfungiblePositionManager.unwrapWETH9(collect0, msg.sender);
        else nonfungiblePositionManager.sweepToken(token0, collect0, msg.sender);
        if (token1 == address(WETH9)) nonfungiblePositionManager.unwrapWETH9(collect1, msg.sender);
        else nonfungiblePositionManager.sweepToken(token1, collect1, msg.sender);

        _stakeToken(key, params.tokenId);
    }

    function _checkAllowance(address token0, address token1) private {
        // tokens should never sit in here for more than a transaction, so we are ok approving max
        if ((IERC20(token0).allowance(address(this), address(nonfungiblePositionManager)) == 0)) {
            IERC20(token0).approve(address(nonfungiblePositionManager), type(uint256).max);
        }
        if ((IERC20(token1).allowance(address(this), address(nonfungiblePositionManager)) == 0)) {
            IERC20(token1).approve(address(nonfungiblePositionManager), type(uint256).max);
        }
    }
}
