// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EasyPosm} from "./utils/libraries/EasyPosm.sol";
import {JITLiquidityHook} from "../src/JITLiquidityHook.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract JITLiquidityHookTest is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    Currency currency0;
    Currency currency1;

    PoolKey poolKey;
    JITLiquidityHook hook;
    PoolId poolId;
    uint256 tokenId;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (0x4444 << 144)
        );
        bytes memory constructorArgs = abi.encode(poolManager);
        deployCodeTo("JITLiquidityHook.sol:JITLiquidityHook", constructorArgs, flags);
        hook = JITLiquidityHook(flags);

        // Create the pool
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = poolKey.toId();
        poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool (so swaps can execute)
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );

        // Approve hook to spend tokens for deposit
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
    }

    function testJITDeposit() public {
        uint256 deposit0 = 50e18;
        uint256 deposit1 = 50e18;

        uint256 hookBal0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookBal1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));

        hook.deposit(poolKey, deposit0, deposit1);

        uint256 hookBal0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookBal1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));

        assertEq(hookBal0After - hookBal0Before, deposit0);
        assertEq(hookBal1After - hookBal1Before, deposit1);
    }

    function testJITBeforeAfterSwap() public {
        hook.deposit(poolKey, 10e18, 10e18);

        // Perform a swap
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // After swap, active position should be cleared
        JITLiquidityHook.ActivePosition memory pos = hook.getActivePosition(poolKey);
        assertEq(pos.liquidity, 0, "Active position should be cleared after swap");

        // Hook should still hold tokens (returned liquidity + fees)
        uint256 hookBal0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookBal1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        assertTrue(hookBal0 + hookBal1 > 0, "Hook should have token balance after swap");
    }

    function testJITNoLiquidityIfEmpty() public {
        // Don't deposit anything — swap should still work
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        JITLiquidityHook.ActivePosition memory pos = hook.getActivePosition(poolKey);
        assertEq(pos.liquidity, 0, "No active position if hook was empty");
    }

    function testJITWithdraw() public {
        uint256 dep0 = 30e18;
        uint256 dep1 = 30e18;
        hook.deposit(poolKey, dep0, dep1);

        uint256 userBal0Before = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 userBal1Before = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        hook.withdraw(poolKey, dep0, dep1);

        uint256 userBal0After = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 userBal1After = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        assertEq(userBal0After - userBal0Before, dep0);
        assertEq(userBal1After - userBal1Before, dep1);
    }

    function testJITMultipleSwaps() public {
        hook.deposit(poolKey, 50e18, 50e18);

        // Perform two swaps — hook adds/removes JIT liquidity each time
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 1
        });

        // After two swaps, hook should still hold the bulk of its tokens
        // (small loss from impermanent loss is expected, but tokens should not be drained)
        uint256 hookBal0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        uint256 hookBal1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        uint256 hookTotal = hookBal0 + hookBal1;

        assertTrue(hookTotal > 90e18, "Hook should retain most of its deposited tokens");

        // Active position should be cleared after each swap
        JITLiquidityHook.ActivePosition memory pos = hook.getActivePosition(poolKey);
        assertEq(pos.liquidity, 0, "Active position should be cleared");
    }
}
