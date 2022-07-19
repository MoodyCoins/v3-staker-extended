// SPDX-License-Identifier: MIT

pragma solidity =0.7.6;
pragma abicoder v2;

import {Test} from 'forge-std/Test.sol';
import {V3StakerExtended, IUniswapV3Staker, IERC20, IERC20Minimal} from '../src/V3StakerExtended.sol';
import {IUniswapV3Factory} from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import {IUniswapV3Pool} from '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import {INonfungiblePositionManager, NonfungiblePositionManager} from '@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol';

uint256 constant MAX_UINT = 2**256 - 1;

contract V3StakerExtendedTest is Test {
    address constant wbtc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant other = 0xC257274276a4E539741Ca11b590B9447B26A8051; // chosen randomly
    IERC20 constant BTC = IERC20(wbtc);
    IERC20 constant WETH = IERC20(weth);
    address me;
    NonfungiblePositionManager nftManager;
    IUniswapV3Factory factory;
    V3StakerExtended staker;
    IUniswapV3Pool pool;
    bytes[] multicallPayload;
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

    function _mint() private returns (uint) {
        delete multicallPayload;
        // arbitrary params, could be anything, all we care about is a new mint occurs
        INonfungiblePositionManager.MintParams memory defaultParams = INonfungiblePositionManager
            .MintParams(
                wbtc,
                weth,
                3000,
                256980,
                258540,
                1000000,
                1 ether,
                0,
                0,
                me,
                block.timestamp + 3000
            );
        bytes memory mintPayload = abi.encodeWithSelector(nftManager.mint.selector, defaultParams);
        multicallPayload.push(mintPayload);
        multicallPayload.push(abi.encodeWithSelector(nftManager.refundETH.selector, new bytes(0))); // refundETH()
        bytes[] memory res = nftManager.multicall{value: 1000 ether}(multicallPayload);
        (uint id, , , ) = abi.decode(res[0], (uint256, uint128, uint256, uint256));
        return id;
    }

    function setUp() public {
        me = address(this);
        factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);
        nftManager = NonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        staker = new V3StakerExtended(factory, nftManager, 2592000, 63072000); // same as official staker
        pool = IUniswapV3Pool(factory.getPool(wbtc, weth, 3000));
        deal(wbtc, me, MAX_UINT);
        deal(me, MAX_UINT);
        WETH.approve(address(nftManager), MAX_UINT);
        BTC.approve(address(nftManager), MAX_UINT);
        tokenId = _mint();
    }

    function _deposit_and_check(uint256 id) internal {
        uint256 initNumDeposits = staker.numDeposits(me);
        nftManager.safeTransferFrom(me, address(staker), id);
        assertEq(staker.numDeposits(me), initNumDeposits + 1);
        assertEq(staker.userDeposits(me, initNumDeposits), id);
    }

    function _withdraw_and_check(uint256 id) internal {
        uint256 initNumDeposits = staker.numDeposits(me);
        uint256 lastIndex = initNumDeposits - 1;
        staker.withdrawToken(id, me, new bytes(0));
        vm.expectRevert(bytes("UniswapV3StakerExtended: index OOB"));
        staker.userDeposits(me, lastIndex);
        assertEq(staker.numDeposits(me), initNumDeposits - 1);
    }

    function test_deposit() public {
        _deposit_and_check(tokenId);
    }

    function test_deposit_revert_bad_index() public {
        vm.expectRevert(bytes("UniswapV3StakerExtended: index OOB"));
        staker.userDeposits(me, 0);
        _deposit_and_check(tokenId);   
        staker.userDeposits(me, 0);
        vm.expectRevert(bytes("UniswapV3StakerExtended: index OOB"));
        staker.userDeposits(me, 1);
    }

    function test_withdrawal() public {
        _deposit_and_check(tokenId);
        _withdraw_and_check(tokenId);
    }

    function test_withdraw_index() public {
        _deposit_and_check(tokenId); // first
        uint secondId = _mint();
        _deposit_and_check(secondId); // second
        uint thirdId = _mint();
        _deposit_and_check(thirdId); // third

        _withdraw_and_check(tokenId);
        _withdraw_and_check(thirdId); // if we have indexining issues it will start to break here
        uint recordedFirstToken = staker.userDeposits(me, 0);
        require(recordedFirstToken != thirdId, "indexing error");
    }

    function test_withdraw_moves_last() public {
        _deposit_and_check(tokenId); // first
        uint newId = _mint();
        _deposit_and_check(newId); // second
        assertEq(staker.userDeposits(me, 1), newId);
        _withdraw_and_check(tokenId); // remove first
        assertEq(staker.numDeposits(me), 1);
        assertEq(staker.userDeposits(me, 0), newId);
    }

    function test_withdraw_moves_last_to_middle() public {
        _deposit_and_check(tokenId); // first
        uint secondId = _mint();
        _deposit_and_check(secondId); // second
        assertEq(staker.userDeposits(me, 1), secondId);
        uint thirdId = _mint();
        _deposit_and_check(thirdId); // third
        assertEq(staker.userDeposits(me, 2), thirdId);


        _withdraw_and_check(secondId); // remove second
        assertEq(staker.numDeposits(me), 2);
        assertEq(staker.userDeposits(me, 1), thirdId);
    }

    function test_withdraw_moves_last_to_front() public {
        _deposit_and_check(tokenId); // first
        uint secondId = _mint();
        _deposit_and_check(secondId); // second
        assertEq(staker.userDeposits(me, 1), secondId);
        uint thirdId = _mint();
        _deposit_and_check(thirdId); // third
        assertEq(staker.userDeposits(me, 2), thirdId);


        _withdraw_and_check(tokenId); // remove second
        assertEq(staker.numDeposits(me), 2);
        assertEq(staker.userDeposits(me, 0), thirdId);
    }

    function test_deposit_withdrawal() public {
        _deposit_and_check(tokenId);
        _withdraw_and_check(tokenId);
        _deposit_and_check(tokenId);
        _withdraw_and_check(tokenId);
    }

    function test_transfer() public {
        _deposit_and_check(tokenId); // first
        uint secondId = _mint();
        _deposit_and_check(secondId); // second
        uint thirdId = _mint();
        _deposit_and_check(thirdId); // third
        staker.transferDeposit(thirdId, other);
        staker.transferDeposit(tokenId, other);
        staker.transferDeposit(secondId, other);
        assertEq(staker.userDeposits(other, 0), thirdId);
        assertEq(staker.userDeposits(other, 1), tokenId);
        assertEq(staker.userDeposits(other, 2), secondId);
    }

    function _mock_incentive() private returns(IUniswapV3Staker.IncentiveKey memory) {
        BTC.approve(address(staker), MAX_UINT);
        IUniswapV3Staker.IncentiveKey memory key = IUniswapV3Staker.IncentiveKey(
            IERC20Minimal(wbtc),
            pool,
            block.timestamp + 1000,
            block.timestamp + 50 days,
            me
        );
        staker.createIncentive(key, 10 * 1e8);
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
        uint newId = _mint();
        nftManager.safeTransferFrom(me, address(staker), newId);
        uint256 initStakedLiquidity = staker.incentiveLiquidity(hashedKey);
        staker.stakeToken(key, newId);
        staker.unstakeToken(key, newId);
        assertEq(initStakedLiquidity, staker.incentiveLiquidity(hashedKey));
        staker.stakeToken(key, newId);
        (, , , , , , , uint256 newLiq, , , , ) = nftManager.positions(newId);
        assertEq(staker.incentiveLiquidity(hashedKey), newLiq + liquidity);
    }
}
