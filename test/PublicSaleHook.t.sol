// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PublicSaleHook} from "../src/PublicSaleHook.sol";

contract PublicSaleHookTest is Test, Deployers {
    uint256 USDT_CAP = 100_000e18;

    PublicSaleHook public saleHook;

    address public usdt;
    address public meta;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        usdt = Currency.unwrap(currency0);
        meta = Currency.unwrap(currency1);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_DONATE_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        deployCodeTo(
            "PublicSaleHook.sol",
            abi.encode(manager, usdt, meta, USDT_CAP),
            address(flags)
        );

        saleHook = PublicSaleHook(address(flags));

        IERC20(usdt).approve(address(saleHook), type(uint256).max);
        IERC20(meta).approve(address(saleHook), type(uint256).max);

        (key,) = initPool(
            Currency.wrap(usdt),
            Currency.wrap(meta),
            saleHook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            SQRT_PRICE_4_1
        );

        int24 tickSpacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: 1_000_000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_deploy() external view {
        assertEq(address(saleHook.poolManager()), address(manager));
        assertEq(Currency.unwrap(saleHook.getMetaCurrency()), meta);
        assertEq(Currency.unwrap(saleHook.getUsdtCurrency()), usdt);
        assertEq(saleHook.getUsdtCap(), USDT_CAP);
    }

    // Rate: 1 USDT = 1 META
    function test_swap_exact_USDT_for_META() external {
        int256 amountIn = -1e18; // exact input 1 USDT

        uint256 usdtInPoolBefore = saleHook.getUsdtInPool();
        uint256 metaInPoolBefore = IERC20(meta).balanceOf(address(this));

        swap(key, true, amountIn, ZERO_BYTES);

        uint256 usdtInPoolAfter = saleHook.getUsdtInPool();
        uint256 metaInPoolAfter = IERC20(meta).balanceOf(address(this));

        assertEq(usdtInPoolAfter - usdtInPoolBefore, uint256(-amountIn));
        assertEq(metaInPoolAfter - metaInPoolBefore, uint256(-amountIn));
    }
}