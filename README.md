## V3 Staker Extended

### Deployments

If you want to try using this contract it is deployed to the following places:

```
Rinkeby: 0xd0Cd2CF5fCc2E83B970Bb2f5Cea3332aFC3F6412
```

#### What is this?

An extension of the [V3 Staker](https://github.com/Uniswap/v3-staker) made by uniswap. In the original contract, not enough information is exposed on-chain to allow for the fetching of basic data. E.g. simple acquisition of a given user's deposits is impossible. In an emergency scenario where users must use the chain to retrieve assets, this is not optimal. This also makes it easier on developers who want to implement v3 staking but don't want to use an indexer.

#### How to use

These contracts expose a few new functions that allow for the enumeration of user deposits, and retrieve the total liquidity deposited in a given incentive. We can get the total number of deposits a user has made into this staker and then retrieve these deposits with the user address and a given index, up to the number of deposits. This function returns the V3 position token Id that has been deposited in the staker.

```
function numDeposits(address)        public returns (uint);
function userDeposits(address, uint) public returns (uint);
```

We can also get the total liquidity deposited into a given incentive with:

```
function incentiveLiquidity(bytes32) public returns (uint)
```

Where bytes32 is the incentiveId for a given incentiveKey. An incentiveKey is a struct built out of:

```
struct IncentiveKey
{
    IERC20Minimal  rewardToken;
    IUniswapV3Pool pool;
    uint256        startTime;
    uint256        endTime;
    address        refundee;
}
```

Please see more in the official github on how to create a new incentive for a pool. We can get the bytes32 incentiveId mentioned above with:

```
keccak256(abi.encode(incentiveKey));
```

**Note**: the constructor accepts the following arguments:

```
constructor(
    IUniswapV3Factory           _factory,
    INonfungiblePositionManager _nonfungiblePositionManager,
    uint256                     _maxIncentiveStartLeadTime,
    uint256                     _maxIncentiveDuration
)
```

Unless you are planning on forking Uniswap V3, you should use the official UniswapV3Factory and NonFungiblePositionManager addresses which are as follows:

```
_factory                    = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
_nonfungiblePositionManager = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
```

#### Final Considerations

The V3 staker is designed to be used by many different people and projects, and could theoretically contain data for many incentives created for multiple pools. These pools each being incentivized by a unique token. This is also true of this contract, as gas requirements do not scale with the number of user deposits, and it is highly unlikely the number of user deposits would ever grow to such as size as to be a hassle to sort through off-chain.

One thing to note when using this contract: _it is entirely possible that a user will have deposits that are staked in a different incentive than yours._ This means that developers need to perform an extra check to see which incentive each tokenId belongs too.

#### Test

Clone this repository and run

```
forge test --fork-url RPC_URL -vv
```

where RPC_URL is some provider for a chain where uniswap v3 is valid and deployed, e.g. an infura provider url.

_Note: This contract has not been audited, use at your own risk._
