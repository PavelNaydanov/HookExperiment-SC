// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

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

        MockERC20(meta).mint(address(saleHook), 1_000_000e18);
        MockERC20(usdt).mint(address(saleHook), 1_000_000e18);

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

    // Rate: 1 USDT = 8 META
    // exact input usdt
    function test_swap_exact_USDT_for_META() external {
        int256 amountInUsdt = -1e18; // exact input 1 USDT
        uint256 desiredAmountOutMeta = 8e18; // desired output 8 META

        uint256 usdtInPoolBefore = saleHook.getUsdtInPool();
        uint256 metaInUserBefore = MockERC20(meta).balanceOf(address(this));

        swap(key, true, amountInUsdt, ZERO_BYTES);

        uint256 usdtInPoolAfter = saleHook.getUsdtInPool();
        uint256 metaInUserAfter = MockERC20(meta).balanceOf(address(this));

        assertEq(usdtInPoolAfter - usdtInPoolBefore, uint256(-amountInUsdt));
        assertEq(metaInUserAfter - metaInUserBefore, desiredAmountOutMeta);
    }

    // Rate: 1 USDT = 8 META
    // exact output meta
    function test_swap_USDT_for_exact_META() external {
        int256 amountOutMeta = 8e18; // exact output 8 META
        uint256 desiredAmountInUsdt = 1e18; // desired input 1 USDT

        uint256 usdtInUserBefore = MockERC20(usdt).balanceOf(address(this));
        uint256 metaInPoolBefore = MockERC20(meta).balanceOf(address(this));

        swap(key, true, amountOutMeta, ZERO_BYTES);

        uint256 usdtInUserAfter = MockERC20(usdt).balanceOf(address(this));
        uint256 metaInPoolAfter = MockERC20(meta).balanceOf(address(this));

        assertEq(usdtInUserBefore - usdtInUserAfter, desiredAmountInUsdt);
        assertEq(metaInPoolAfter - metaInPoolBefore, uint256(amountOutMeta));
    }

    // Rate: 1 USDT = 8 META
    // exact input META
    function test_swap_exact_META_for_USDT() external {
        int256 amountInMeta = -8e18; // exact input 8 META
        uint256 desiredAmountOutUsdt = 1e18; // desired output 1 USDT

        uint256 usdtInUserBefore = MockERC20(usdt).balanceOf(address(this));
        uint256 metaInUserBefore = MockERC20(meta).balanceOf(address(this));

        swap(key, false, amountInMeta, ZERO_BYTES);

        uint256 usdtInUserAfter = MockERC20(usdt).balanceOf(address(this));
        uint256 metaInUserAfter = MockERC20(meta).balanceOf(address(this));

        assertEq(usdtInUserAfter - usdtInUserBefore, desiredAmountOutUsdt);
        assertEq(metaInUserBefore - metaInUserAfter, uint256(-amountInMeta));
    }

    // Rate: 1 USDT = 8 META
    // exact input USDT
    function test_swap_META_for_exact_USDT() external {
        int256 amountOutUSDT = 1e18; // exact input 1 USDT
        uint256 desiredAmountInMeta = 8e18; // desired output 8 USDT

        uint256 usdtInUserBefore = MockERC20(usdt).balanceOf(address(this));
        uint256 metaInUserBefore = MockERC20(meta).balanceOf(address(this));

        swap(key, false, amountOutUSDT, ZERO_BYTES);

        uint256 usdtInUserAfter = MockERC20(usdt).balanceOf(address(this));
        uint256 metaInUserAfter = MockERC20(meta).balanceOf(address(this));

        assertEq(usdtInUserAfter - usdtInUserBefore, uint256(amountOutUSDT));
        assertEq(metaInUserBefore - metaInUserAfter, desiredAmountInMeta);
    }

    function test_swap_when_usdt_cap_reached() external {
        // Swap in USDT until cap is reached
        swap(key, true, -int256(USDT_CAP), ZERO_BYTES);

        assertTrue(saleHook.isUsdtCapReached());

        int256 amountInUsdt = -1e18; // exact input 1 USDT
        uint256 desiredAmountOutMeta = 4e18; // desired output 4 META

        uint256 metaInUserBefore = MockERC20(meta).balanceOf(address(this));

        // Swap in META should still work
        swap(key, true, amountInUsdt, ZERO_BYTES);

        uint256 metaInUserAfter= MockERC20(meta).balanceOf(address(this));

        assertLt(metaInUserAfter - metaInUserBefore, desiredAmountOutMeta);
    }
}
