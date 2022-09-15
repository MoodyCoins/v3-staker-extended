# V3 Staker Extended

## What is this?

An extension of the [V3 Staker](https://github.com/Uniswap/v3-staker) made by uniswap. In the original contract, not enough information is exposed on-chain to allow for the fetching of basic data. E.g. simple acquisition of a given user's deposits is impossible. In an emergency scenario where users must use the chain to retrieve assets, this is not optimal. This also makes it easier on developers who want to implement v3 staking but don't want to implement something like The Graph.

This contract also allows users to increase and decrease liquidity for their staked NFT positions without having to perform multiple steps. This more closely models the functionality of the traditional MasterChef contract.

## How to use

### User Deposits

These contracts expose a few new functions. The first of which allow for the enumeration of user deposits. We can get the total number of deposits a user has made into this staker and then retrieve these deposits with the user address and a given index, up to the number of deposits. ```userDeposits``` returns the V3 liquidity position nft token Id that has been deposited in the staker.

```solidity
function numDeposits(address user) external view returns (uint);
function userDeposits(address user, uint256 index) external view returns (uint256 tokenId);
function userDepositsIndex(uint tokenId) external view returns (uint256 index);
```

Where bytes32 is the incentiveId for a given incentiveKey. An incentiveKey is a struct built out of:

```solidity
struct IncentiveKey 
{
    IERC20Minimal  rewardToken;
    IUniswapV3Pool pool;
    uint256        startTime;
    uint256        endTime;
    address        refundee;
}
```

We can get the incentiveId mentioned above with:

```solidity
bytes32 incentiveId = keccak256(abi.encode(incentiveKey));
```

### Incentive Liquidity and Management

We can get the total liquidity deposited into a given incentive with:

```solidity
function incentiveLiquidity(bytes32) public returns (uint)
```

We can also change the total token incentives for a given incentive with:

```solidity
function alterIncentive(
    IncentiveKey memory key,
    uint256 tokenChange,
    bool increase
) external onlyOwner;
```

### Liquidity Management

This contract exposes a few functions that allow us to manage our staked liquidity. For obvious reasons they can only be called when the given ```tokenId``` is staked inside the contract. The ```msg.sender``` must also be the one that initially deposited the token. An increase in liquidity requires the user to have approved the staker contract to spend ```token0``` and ```token1``` (the constituent tokens of the liquidity pool). ```increaseLiquidity``` is marked as payable to allow increasing liquidity for an ETH/XXX liquidity position by sending raw ETH to the contract.

```solidity
function increaseLiquidity(
    IncentiveKey memory key,
    IncreaseLiquidityParams calldata params
)
    external
    payable
    returns (
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

function decreaseLiquidity(
    IncentiveKey memory key,
    DecreaseLiquidityParams calldata params
) 
    external  
    returns (
        uint256 amount0, 
        uint256 amount1
    )
```

The return values of these functions are the amounts of ```token0``` and ```token1``` taken from or sent to the user. ```liquidity``` is the exact amount of liquidity that has been added to the position. The necessary params are defined as follows

```solidity
struct IncreaseLiquidityParams {
    uint256 tokenId;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

struct DecreaseLiquidityParams {
    uint256 tokenId;
    uint128 liquidity;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}
```

## Final Considerations

**Note**: the constructor accepts the following arguments:

```solidity
constructor(
    IUniswapV3Factory _factory,
    INonfungiblePositionManager _nonfungiblePositionManager,
    uint256 _maxIncentiveStartLeadTime,
    uint256 _maxIncentiveDuration,
    address _weth9
)
```

Unless you are planning on forking Uniswap V3, you should use the official UniswapV3Factory and NonFungiblePositionManager addresses (on mainnet) which are as follows:

```solidity
_factory                    = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
_nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
```

### Usage

The V3 staker was designed to be used by many different people and projects, and could theoretically contain data for many incentives created for multiple pools. These pools each being incentivized by a unique token. This is technically also true of this contract, as gas requirements do not scale with the number of user deposits.

But for a variety of reasons this is not the ideal way to use this contract. It is entirely possible that a user will have deposits that are staked in a different incentive than yours. This means that developers need to perform an extra check to see which incentive each tokenId belongs too. This could quickly become cumbersome if multiple projects with many different incentives used the same contract.

More importantly, we have marked a number of functions as ```onlyOwner```, namely ```alterIncentive```, ```endIncentive```, and ```createIncentive```. This essentially requires that each project deploy their own ```V3StakerExtended``` contract, instead of sharing the same as intended by the original design. This is a deliberate design choice that we believe more closely models the MasterChef contract, and we believe that it is likely developers would opt to use their own deployed contracts rather than the universally deployed Uniswap V3 staker anyways.

## Test

Clone this repository and run

```zsh
forge test --fork-url RPC_URL -vv
```

where RPC_URL is a provider pointing to mainnet, e.g. an infura provider url. You may have to set compiler optimizer to one million runs for it to compile.

_Note: This contract has not been audited, use at your own risk._
