// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity =0.7.6;
pragma abicoder v2;

import '@uniswap/v3-staker/contracts/interfaces/IUniswapV3Staker.sol';

/// @title Extended Uniswap V3 Staker Interface
interface IUniswapV3StakerExtended {
    /// @param incentiveId the id of the incentive
    /// @param increase the increase in liquidity
    event IncentiveAltered(bytes32 indexed incentiveId, uint256 increase);

    /// @notice Get the liquidity for a given incentive
    /// @dev incentiveLiquidity[hashedIncentiveKey] => totalLiquidityStakedInIncentive
    /// @param incentiveId Id of the desired incentive
    /// @return The net liquidity deposited in that incentive
    function incentiveLiquidity(bytes32 incentiveId) external view returns (uint256);

    /// @notice Get the number of deposits a user has
    /// @dev numDeposits[user] => numberOfUserDeposits
    /// @param user Address of the user
    /// @return The number of nfts the user has deposited in this contract
    function numDeposits(address user) external view returns (uint256);

    /// @notice Get the tokenId of a user deposit by index
    /// @dev Reverts on a bad index
    /// @param user The address to check
    /// @param index The index of the deposit
    /// @return tokenId The tokenId of the requested deposit
    function userDeposits(address user, uint256 index) external view returns (uint256 tokenId);

    /// @notice Get the index value of a tokenId
    /// @dev Reverts if the user tokenId has not been deposited into the staker
    /// @param tokenId The tokenId to check
    /// @return index The index of the tokenId
    function userDepositsIndex(uint256 tokenId) external view returns (uint256 index);

    /// @notice Increase the amount of reward token for a given incentive
    /// @dev Warning: this will alter unclaimed stakes by the proportional percentage you change
    /// @param key The incentive key
    /// @param tokenChange The amount of incentive token to add (or remove) from the rewards
    function increaseIncentive(IUniswapV3Staker.IncentiveKey memory key, uint256 tokenChange)
        external;

    /// @notice Increase the liquidity of a staked V3 NFT position
    /// @param key The incentive key of the incentive the position is staked in
    /// @param params The increase liquidity params
    /// @return liquidity The amount of liquidity added to the position
    /// @return amount0 The amount of token0 added to the position
    /// @return amount1 The amount of token1 added to the position
    function increaseLiquidity(
        IUniswapV3Staker.IncentiveKey memory key,
        INonfungiblePositionManager.IncreaseLiquidityParams calldata params
    )
        external
        payable
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    /// @notice Decrease the liquidity of a staked V3 NFT position
    /// @param key The incentive key of the incentive the position is staked in
    /// @param params The decrease liquidity params
    /// @return amount0 The amount of token0 sent back to the user from the position
    /// @return amount1 The amount of token1 sent back to the user from the position
    function decreaseLiquidity(
        IUniswapV3Staker.IncentiveKey memory key,
        INonfungiblePositionManager.DecreaseLiquidityParams calldata params
    ) external returns (uint256 amount0, uint256 amount1);
}
