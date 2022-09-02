// SPDX-License-Identifier: MIT

pragma solidity =0.7.6;
pragma abicoder v2;

import {Test} from 'forge-std/Test.sol';
import {V3StakerExtended, IUniswapV3Staker, IERC20, IERC20Minimal} from '../src/V3StakerExtended.sol';
import {IUniswapV3Factory} from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import {IUniswapV3Pool} from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import {INonfungiblePositionManager, NonfungiblePositionManager} from '@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol';
import {LiquidityAmounts} from '@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol';
import {TickMath} from '@uniswap/v3-core/contracts/libraries/TickMath.sol';

uint256 constant MAX_UINT = 2**256 - 1;

// TODO: make everything public in the contract so we can test more thoroughly

contract V3StakerExtendedTest is Test {
    address me;
    address constant other = 0xC257274276a4E539741Ca11b590B9447B26A8051; // chosen randomly

    address constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // arbitrarily taken from a random deposit I saw on chain. The vlaues are not important.
    // All we want is to mint a new token.
    int24 tickLower = 201240;
    int24 tickUpper = 203280;
    uint256 amount0Add = 150502235;
    uint256 amount1Add = 282919998644294734;

    IERC20 constant USDC = IERC20(usdc);
    IERC20 constant WETH = IERC20(weth);
    uint24 constant poolFee = 500;

    NonfungiblePositionManager nftManager;
    IUniswapV3Factory factory;
    V3StakerExtended staker;
    IUniswapV3Pool pool;

    uint256 tokenId;

    receive() external payable {} // for incoming weth transfers

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _mint() private returns (uint256) {
        INonfungiblePositionManager.MintParams memory defaultParams = INonfungiblePositionManager
            .MintParams({
                token0: usdc,
                token1: weth,
                fee: poolFee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Add,
                amount1Desired: amount1Add,
                amount0Min: 0,
                amount1Min: 0,
                recipient: me,
                deadline: block.timestamp + 1
            });

        (uint256 id, , , ) = nftManager.mint(defaultParams);

        return id;
    }

    function setUp() public {
        me = address(this);
        factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        nftManager = NonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        staker = new V3StakerExtended(factory, nftManager, 2592000, 63072000, weth); // same as official staker

        pool = IUniswapV3Pool(factory.getPool(usdc, weth, poolFee));
        assert(address(pool) != address(0));

        deal(usdc, me, 10000 ether);
        deal(weth, me, 10000 ether);

        WETH.approve(address(nftManager), MAX_UINT);
        USDC.approve(address(nftManager), MAX_UINT);

        tokenId = _mint();
    }

    /*//////////////////////////////////////////////////////////
                           INDEXING TESTS                       
    //////////////////////////////////////////////////////////*/

    function _deposit_and_check(uint256 id) internal {
        uint256 initNumDeposits = staker.numDeposits(me);

        nftManager.safeTransferFrom(me, address(staker), id);

        assertEq(staker.numDeposits(me), initNumDeposits + 1);
        assertEq(staker.userDeposits(me, initNumDeposits), id);
        assertEq(staker.userDepositsIndex(id), initNumDeposits);
    }

    function _withdraw_and_check(uint256 id) internal {
        uint256 initNumDeposits = staker.numDeposits(me);

        // one deposit, so should clear everything
        if (initNumDeposits == 1) {
            staker.withdrawToken(id, me, new bytes(0));

            vm.expectRevert(bytes('UniswapV3StakerExtended: index OOB'));
            staker.userDeposits(me, 0);

            vm.expectRevert(bytes('UniswapV3StakerExtended: token not deposited'));
            staker.userDepositsIndex(id);

            assertEq(staker.numDeposits(me), 0);

            return;
        }

        uint256 lastIndex = initNumDeposits - 1;

        uint256 indexOfId = staker.userDepositsIndex(id);

        uint256 lastId = staker.userDeposits(me, lastIndex);

        uint256 secondToLastId = staker.userDeposits(me, lastIndex - 1);
        uint256 secondToLastIndex = lastIndex - 1;

        // should just pop, making the secondToLast the last
        if (indexOfId == lastIndex) {
            staker.withdrawToken(id, me, new bytes(0));

            // numDeposits should reduce by 1
            assertEq(staker.numDeposits(me), initNumDeposits - 1);

            // lastIndex should throw now
            vm.expectRevert(bytes('UniswapV3StakerExtended: index OOB'));
            staker.userDeposits(me, lastIndex);

            // removed Id should throw now
            vm.expectRevert(bytes('UniswapV3StakerExtended: token not deposited'));
            staker.userDepositsIndex(id);

            // this shouldn't change, we just popped the last and didn't touch anything else
            assertEq(staker.userDeposits(me, secondToLastIndex), secondToLastId);

            // this shouldn't change, we just popped the last and didn't touch anything else
            assertEq(staker.userDepositsIndex(secondToLastId), secondToLastIndex);

            return;
        }
        // should swap given and last, then delete last
        else {
            staker.withdrawToken(id, me, new bytes(0));

            // numDeposits should reduce by 1
            assertEq(staker.numDeposits(me), initNumDeposits - 1);

            // lastIndex should throw now
            vm.expectRevert(bytes('UniswapV3StakerExtended: index OOB'));
            staker.userDeposits(me, lastIndex);

            // removed Id should throw now
            vm.expectRevert(bytes('UniswapV3StakerExtended: token not deposited'));
            staker.userDepositsIndex(id);

            // Index of the (previously) lastId should have swapped with the index removed id
            assertEq(staker.userDepositsIndex(lastId), indexOfId);

            // Token at index of the removed Id should be the (previously) lastId
            assertEq(staker.userDeposits(me, indexOfId), lastId);

            return;
        }
    }

    function test_deposit() public {
        _deposit_and_check(tokenId);
    }

    function test_deposit_revert_bad_index() public {
        vm.expectRevert(bytes('UniswapV3StakerExtended: index OOB'));
        staker.userDeposits(me, 0);
        _deposit_and_check(tokenId);
        staker.userDeposits(me, 0);
        vm.expectRevert(bytes('UniswapV3StakerExtended: index OOB'));
        staker.userDeposits(me, 1);
    }

    function test_withdrawal() public {
        _deposit_and_check(tokenId);
        _withdraw_and_check(tokenId);
    }

    function test_withdraw_first_and_last() public {
        _deposit_and_check(tokenId); // first

        uint256 secondId = _mint();
        _deposit_and_check(secondId); // second

        uint256 thirdId = _mint();
        _deposit_and_check(thirdId); // third

        _withdraw_and_check(tokenId);
        _withdraw_and_check(thirdId);

        uint256 recordedFirstToken = staker.userDeposits(me, 0);
        assertEq(recordedFirstToken, secondId);
    }

    function test_withdraw_moves_last() public {
        _deposit_and_check(tokenId); // first

        uint256 newId = _mint();
        _deposit_and_check(newId); // second
        assertEq(staker.userDeposits(me, 1), newId);

        _withdraw_and_check(tokenId); // remove first

        assertEq(staker.numDeposits(me), 1);
        assertEq(staker.userDeposits(me, 0), newId);
    }

    function test_withdraw_moves_last_to_middle() public {
        _deposit_and_check(tokenId); // first

        uint256 secondId = _mint();
        _deposit_and_check(secondId); // second
        assertEq(staker.userDeposits(me, 1), secondId);

        uint256 thirdId = _mint();
        _deposit_and_check(thirdId); // third
        assertEq(staker.userDeposits(me, 2), thirdId);

        _withdraw_and_check(secondId); // remove second

        assertEq(staker.numDeposits(me), 2);
        assertEq(staker.userDeposits(me, 1), thirdId);
    }

    function test_withdraw_moves_last_to_front() public {
        _deposit_and_check(tokenId); // first

        uint256 secondId = _mint();
        _deposit_and_check(secondId); // second
        assertEq(staker.userDeposits(me, 1), secondId);

        uint256 thirdId = _mint();
        _deposit_and_check(thirdId); // third
        assertEq(staker.userDeposits(me, 2), thirdId);

        _withdraw_and_check(tokenId); // remove second

        assertEq(staker.numDeposits(me), 2);
        assertEq(staker.userDeposits(me, 0), thirdId);
    }

    function test_deposit_withdrawal_repeat() public {
        _deposit_and_check(tokenId);
        _withdraw_and_check(tokenId);
        _deposit_and_check(tokenId);
        _withdraw_and_check(tokenId);
        _deposit_and_check(tokenId);
        _withdraw_and_check(tokenId);
    }

    function test_transfer_deposit() public {
        _deposit_and_check(tokenId); // first

        uint256 secondId = _mint();
        _deposit_and_check(secondId); // second

        uint256 thirdId = _mint();
        _deposit_and_check(thirdId); // third

        staker.transferDeposit(thirdId, other);
        staker.transferDeposit(tokenId, other);
        staker.transferDeposit(secondId, other);

        assertEq(staker.userDeposits(other, 0), thirdId);
        assertEq(staker.userDepositsIndex(thirdId), 0);

        assertEq(staker.userDeposits(other, 1), tokenId);
        assertEq(staker.userDepositsIndex(tokenId), 1);

        assertEq(staker.userDeposits(other, 2), secondId);
        assertEq(staker.userDepositsIndex(secondId), 2);
    }

    /*//////////////////////////////////////////////////////////
                          LIQUIDITY TESTS                       
    //////////////////////////////////////////////////////////*/

    function _mock_incentive() private returns (IUniswapV3Staker.IncentiveKey memory) {
        USDC.approve(address(staker), MAX_UINT);
        IUniswapV3Staker.IncentiveKey memory key = IUniswapV3Staker.IncentiveKey(
            IERC20Minimal(usdc),
            pool,
            block.timestamp + 1000,
            block.timestamp + 50 days,
            me
        );
        staker.createIncentive(key, 10 * 1e6);
        skip(2000);
        return key;
    }

    function test_incentive_liquidity_add() public {
        _deposit_and_check(tokenId);

        IUniswapV3Staker.IncentiveKey memory key = _mock_incentive();
        bytes32 hashedKey = keccak256(abi.encode(key));
        (, , , , , , , uint256 liquidity, , , , ) = nftManager.positions(tokenId);

        uint256 initStakedLiquidity = staker.incentiveLiquidity(hashedKey);
        assertEq(initStakedLiquidity, 0);

        staker.stakeToken(key, tokenId);

        assertEq(staker.incentiveLiquidity(hashedKey), liquidity);
    }

    function test_incentive_liquidity_withdraw() public {
        _deposit_and_check(tokenId);

        IUniswapV3Staker.IncentiveKey memory key = _mock_incentive();
        bytes32 hashedKey = keccak256(abi.encode(key));
        (, , , , , , , uint256 liquidity, , , , ) = nftManager.positions(tokenId);

        staker.stakeToken(key, tokenId);

        uint256 newId = _mint();

        nftManager.safeTransferFrom(me, address(staker), newId);

        uint256 initStakedLiquidity = staker.incentiveLiquidity(hashedKey);

        staker.stakeToken(key, newId);
        staker.unstakeToken(key, newId);

        assertEq(initStakedLiquidity, staker.incentiveLiquidity(hashedKey));

        staker.stakeToken(key, newId);

        (, , , , , , , uint256 newLiq, , , , ) = nftManager.positions(newId);
        // both deposits should be accounted for
        assertEq(staker.incentiveLiquidity(hashedKey), newLiq + liquidity);
    }

    // TODO: probably a few more checks we can do here with
    // (liq, am0, am1) = increaseLiquidity etc
    // TODO: actually we really need to test those return values

    function test_increase_liquidity() public {
        _deposit_and_check(tokenId);

        IUniswapV3Staker.IncentiveKey memory key = _mock_incentive();
        staker.stakeToken(key, tokenId);

        deal(weth, me, 10000 ether);

        WETH.approve(address(staker), MAX_UINT);
        USDC.approve(address(staker), MAX_UINT);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams(
                tokenId, // id
                amount0Add, // amount0desired
                amount1Add, // amount1desired
                0, // amount0min
                0, // amount1min
                block.timestamp // deadline
            );

        (, , , , , , , uint128 initLiq, , , , ) = nftManager.positions(tokenId);

        uint256 initUsdcBal = USDC.balanceOf(me);
        uint256 initWethBal = WETH.balanceOf(me);

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        uint256 newLiqAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0Add,
            amount1Add
        );

        staker.increaseLiquidity(key, params);

        (, , , , , , , uint128 finalLiq, , , , ) = nftManager.positions(tokenId);

        assert(initUsdcBal > USDC.balanceOf(me));
        assert(initWethBal > WETH.balanceOf(me));

        // liquidity should increase
        assertEq(finalLiq, newLiqAdded + initLiq);

        (address liqOwner, uint48 numberOfStakes, , ) = staker.deposits(tokenId);
        assertEq(liqOwner, me);
        assertEq(uint256(numberOfStakes), 1);

        assertEq(staker.incentiveLiquidity(keccak256(abi.encode(key))), newLiqAdded + initLiq);
    }

    function test_increase_liquidity_with_msg_value() public {
        _deposit_and_check(tokenId);

        IUniswapV3Staker.IncentiveKey memory key = _mock_incentive();
        staker.stakeToken(key, tokenId);

        deal(me, 10000 ether);

        USDC.approve(address(staker), MAX_UINT);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams(
                tokenId, // id
                amount0Add, // amount0desired
                amount1Add, // amount1desired
                0, // amount0min
                0, // amount1min
                block.timestamp // deadline
            );

        (, , , , , , , uint128 initLiq, , , , ) = nftManager.positions(tokenId);

        uint256 initUsdcBal = USDC.balanceOf(me);
        uint256 initEthBal = me.balance;

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
        uint256 newLiqAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amount0Add,
            amount1Add
        );

        (, , uint256 amountEthDeposited) = staker.increaseLiquidity{value: 10 ether}(key, params);

        (, , , , , , , uint128 finalLiq, , , , ) = nftManager.positions(tokenId);

        assert(initUsdcBal > USDC.balanceOf(me));
        assert(initEthBal > me.balance);
        assertEq(me.balance, initEthBal - amountEthDeposited);

        // liquidity should increase
        assertEq(finalLiq, newLiqAdded + initLiq);

        (address liqOwner, uint48 numberOfStakes, , ) = staker.deposits(tokenId);
        assertEq(liqOwner, me);
        assertEq(uint256(numberOfStakes), 1);

        assertEq(staker.incentiveLiquidity(keccak256(abi.encode(key))), newLiqAdded + initLiq);
    }

    function test_decrease_liquidity() public {
        _deposit_and_check(tokenId);

        IUniswapV3Staker.IncentiveKey memory key = _mock_incentive();
        staker.stakeToken(key, tokenId);

        (, , , , , , , uint128 liquidity, , , , ) = nftManager.positions(tokenId);
        uint128 halfLiquidity = liquidity / 2;

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams(
                tokenId, // id
                halfLiquidity, // liquidity
                0, // amount0Min
                0, // amount1Min
                block.timestamp // deadline
            );

        (, , , , , , , uint128 initLiq, , , , ) = nftManager.positions(tokenId);

        uint256 initUsdcBal = USDC.balanceOf(me);
        uint256 initWethBal = WETH.balanceOf(me);

        (uint256 collected0, uint256 collected1) = staker.decreaseLiquidity(key, params);

        assert(collected0 > 0);
        assert(collected1 > 1);

        (, , , , , , , uint128 finalLiq, , , , ) = nftManager.positions(tokenId);

        // balances should increase
        assert(initUsdcBal < USDC.balanceOf(me));
        assert(initWethBal < WETH.balanceOf(me));

        // liquidity should decrease by half
        assertEq(finalLiq, uint256(initLiq) - halfLiquidity);

        (address liqOwner, uint48 numberOfStakes, , ) = staker.deposits(tokenId);
        assertEq(liqOwner, me);
        assertEq(uint256(numberOfStakes), 1);

        assertEq(
            staker.incentiveLiquidity(keccak256(abi.encode(key))),
            uint256(initLiq) - halfLiquidity
        );
    }

    function test_decrease_liquidity_revert_not_stake_owner() public {
        _deposit_and_check(tokenId);

        IUniswapV3Staker.IncentiveKey memory key = _mock_incentive();
        staker.stakeToken(key, tokenId);

        (, , , , , , , uint128 liquidity, , , , ) = nftManager.positions(tokenId);
        uint128 halfLiquidity = liquidity / 2;

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams(
                tokenId, // id
                halfLiquidity, // liquidity
                0, // amount0Min
                0, // amount1Min
                block.timestamp // deadline
            );

        staker.transferDeposit(tokenId, other);

        vm.expectRevert(bytes('UniswapV3Staker::withdrawToken: only owner can decrease liquidity'));
        staker.decreaseLiquidity(key, params);
    }
}
