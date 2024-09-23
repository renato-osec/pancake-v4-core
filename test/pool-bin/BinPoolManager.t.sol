// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "../../src/libraries/LPFeeLibrary.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IProtocolFees} from "../../src/interfaces/IProtocolFees.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IBinPoolManager} from "../../src/pool-bin/interfaces/IBinPoolManager.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";
import {Vault} from "../../src/Vault.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolId} from "../../src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../../src/types/BalanceDelta.sol";
import {BinPoolManager} from "../../src/pool-bin/BinPoolManager.sol";
import {MockBinHooks} from "../../src/test/pool-bin/MockBinHooks.sol";
import {MockFeeManagerHook} from "../../src/test/fee/MockFeeManagerHook.sol";
import {MockProtocolFeeController} from "../../src/test/fee/MockProtocolFeeController.sol";
import {BinPool} from "../../src/pool-bin/libraries/BinPool.sol";
import {LiquidityConfigurations} from "../../src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "../../src/pool-bin/libraries/math/PackedUint128Math.sol";
import {SafeCast} from "../../src/pool-bin/libraries/math/SafeCast.sol";
import {BinPoolParametersHelper} from "../../src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Constants} from "../../src/pool-bin/libraries/Constants.sol";
import "../../src/pool-bin/interfaces/IBinHooks.sol";
import {BinFeeManagerHook} from "./helpers/BinFeeManagerHook.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {IBinHooks} from "../../src/pool-bin/interfaces/IBinHooks.sol";
import {BinSwapHelper} from "./helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "./helpers/BinLiquidityHelper.sol";
import {BinDonateHelper} from "./helpers/BinDonateHelper.sol";
import {BinTestHelper} from "./helpers/BinTestHelper.sol";
import {Hooks} from "../../src/libraries/Hooks.sol";
import {ParametersHelper} from "../../src/libraries/math/ParametersHelper.sol";
import {BinPosition} from "../../src/pool-bin/libraries/BinPosition.sol";
import {PriceHelper} from "../../src/pool-bin/libraries/PriceHelper.sol";
import {BinHelper} from "../../src/pool-bin/libraries/BinHelper.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract BinPoolManagerTest is Test, GasSnapshot, BinTestHelper {
    using SafeCast for uint256;
    using PackedUint128Math for bytes32;
    using PackedUint128Math for uint128;
    using BinPoolParametersHelper for bytes32;
    using PriceHelper for uint24;
    using BinHelper for bytes32;

    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error PoolInvalidParameter();
    error CurrenciesInitializedOutOfOrder();
    error MaxBinStepTooSmall(uint16 maxBinStep);
    error ContractSizeTooLarge(uint256 diff);

    event ProtocolFeeUpdated(PoolId indexed id, uint24 protocolFees);
    event SetMaxBinStep(uint16 maxBinStep);
    event DynamicLPFeeUpdated(PoolId indexed id, uint24 dynamicSwapFee);

    Vault public vault;
    BinPoolManager public poolManager;
    BinSwapHelper public binSwapHelper;
    BinLiquidityHelper public binLiquidityHelper;
    BinDonateHelper public binDonateHelper;

    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    PoolKey key;
    bytes32 poolParam;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)));

        vault.registerApp(address(poolManager));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        IBinPoolManager iBinPoolManager = IBinPoolManager(address(poolManager));
        IVault iVault = IVault(address(vault));

        binSwapHelper = new BinSwapHelper(iBinPoolManager, iVault);
        binLiquidityHelper = new BinLiquidityHelper(iBinPoolManager, iVault);
        binDonateHelper = new BinDonateHelper(iBinPoolManager, iVault);

        token0.approve(address(binSwapHelper), 1000 ether);
        token1.approve(address(binSwapHelper), 1000 ether);
        token0.approve(address(binLiquidityHelper), 1000 ether);
        token1.approve(address(binLiquidityHelper), 1000 ether);
        token0.approve(address(binDonateHelper), 1000 ether);
        token1.approve(address(binDonateHelper), 1000 ether);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
    }

    function test_bytecodeSize() public {
        snapSize("BinPoolManagerBytecodeSize", address(poolManager));

        // forge coverage will run with '--ir-minimum' which set optimizer run to min
        // thus we do not want to revert for forge coverage case
        if (vm.envExists("FOUNDRY_PROFILE") && address(poolManager).code.length > 24576) {
            revert ContractSizeTooLarge(address(poolManager).code.length - 24576);
        }
    }

    function testInitialize_gasCheck_withoutHooks() public {
        snapStart("BinPoolManagerTest#testInitialize_gasCheck_withoutHooks");
        poolManager.initialize(key, activeId, new bytes(0));
        snapEnd();
    }

    function test_FuzzInitializePool(uint16 binStep) public {
        binStep = uint16(bound(binStep, poolManager.MIN_BIN_STEP(), poolManager.MAX_BIN_STEP()));

        uint16 bitMap = 0x0008; // after mint call
        MockBinHooks mockHooks = new MockBinHooks();
        mockHooks.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            // hooks: hook,
            hooks: IHooks(address(mockHooks)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(bitMap)).setBinStep(binStep)
        });

        vm.expectEmit();
        emit IBinPoolManager.Initialize(
            key.toId(), key.currency0, key.currency1, IHooks(address(mockHooks)), key.fee, key.parameters, activeId
        );

        poolManager.initialize(key, activeId, new bytes(0));

        (Currency curr0, Currency curr1, IHooks hooks, IPoolManager pm, uint24 fee, bytes32 parameters) =
            poolManager.poolIdToPoolKey(key.toId());
        assertEq(Currency.unwrap(curr0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(curr1), Currency.unwrap(key.currency1));
        assertEq(address(hooks), address(key.hooks));
        assertEq(address(pm), address(key.poolManager));
        assertEq(fee, key.fee);
        assertEq(parameters, key.parameters);
    }

    function test_FuzzInitializePoolUnusedBits(uint256 randomOneBitOffset) external {
        randomOneBitOffset = bound(randomOneBitOffset, BinPoolParametersHelper.OFFSET_MOST_SIGNIFICANT_UNUSED_BITS, 255);

        uint16 bitMap = 0x0008; // after mint call
        MockBinHooks mockHooks = new MockBinHooks();
        mockHooks.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            // hooks: hook,
            hooks: IHooks(address(mockHooks)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(bitMap) | (1 << randomOneBitOffset)).setBinStep(1)
        });

        vm.expectRevert(abi.encodeWithSelector(ParametersHelper.UnusedBitsNonZero.selector));
        poolManager.initialize(key, activeId, new bytes(0));
    }

    function testInitializeHookValidation() public {
        uint16 bitMap = 0x0008; // after mint call
        MockBinHooks mockHooks = new MockBinHooks();
        mockHooks.setHooksRegistrationBitmap(bitMap);

        // hook config
        {
            key = PoolKey({
                currency0: currency0,
                currency1: currency1,
                // hooks: hook,
                hooks: IHooks(address(mockHooks)),
                poolManager: IPoolManager(address(poolManager)),
                fee: uint24(3000), // 3000 = 0.3%
                parameters: bytes32(uint256(bitMap - 1)).setBinStep(10)
            });
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookConfigValidationError.selector));
            poolManager.initialize(key, activeId, new bytes(0));
        }

        // hook permission
        {
            bitMap = uint16(1 << HOOKS_AFTER_BURN_RETURNS_DELTA_OFFSET);
            mockHooks.setHooksRegistrationBitmap(bitMap);
            key = PoolKey({
                currency0: currency0,
                currency1: currency1,
                // hooks: hook,
                hooks: IHooks(address(mockHooks)),
                poolManager: IPoolManager(address(poolManager)),
                fee: uint24(3000), // 3000 = 0.3%
                parameters: bytes32(uint256(bitMap)).setBinStep(10)
            });
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookPermissionsValidationError.selector));
            poolManager.initialize(key, activeId, new bytes(0));
        }
    }

    function testInitializeSamePool() public {
        poolManager.initialize(key, 10, new bytes(0));

        vm.expectRevert(PoolAlreadyInitialized.selector);
        poolManager.initialize(key, 10, new bytes(0));
    }

    function testInitializeDynamicFeeTooLarge(uint24 dynamicSwapFee) public {
        dynamicSwapFee = uint24(bound(dynamicSwapFee, LPFeeLibrary.TEN_PERCENT_FEE + 1, type(uint24).max));

        uint16 bitMap = 0x0040; // 0000 0000 0100 0000 (before swap call)
        BinFeeManagerHook binFeeManagerHook = new BinFeeManagerHook(poolManager);
        binFeeManagerHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(binFeeManagerHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(bitMap)).setBinStep(10)
        });

        binFeeManagerHook.setFee(dynamicSwapFee);

        vm.prank(address(binFeeManagerHook));
        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, dynamicSwapFee));
        poolManager.updateDynamicLPFee(key, dynamicSwapFee);
    }

    function testInitializeInvalidFee() public {
        uint16 bitMap = 0x0040; // 0000 0000 0100 0000 (before swap call)
        BinFeeManagerHook binFeeManagerHook = new BinFeeManagerHook(poolManager);
        binFeeManagerHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(binFeeManagerHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG + 1,
            parameters: bytes32(uint256(bitMap)).setBinStep(10)
        });

        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, key.fee));
        poolManager.initialize(key, 10, new bytes(0));
    }

    function testInitializeInvalidId() public {
        vm.expectRevert(PoolInvalidParameter.selector);
        poolManager.initialize(key, 0, new bytes(0));
    }

    function testInitializeSwapFeeTooLarge() public {
        uint24 swapFee = LPFeeLibrary.TEN_PERCENT_FEE + 1;

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: swapFee,
            parameters: poolParam.setBinStep(1) // binStep
        });

        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, swapFee));
        poolManager.initialize(key, activeId, "");
    }

    function testInitializeInvalidBinStep() public {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(poolManager.MIN_BIN_STEP() - 1) // binStep
        });

        vm.expectRevert(
            abi.encodeWithSelector(IBinPoolManager.BinStepTooSmall.selector, poolManager.MIN_BIN_STEP() - 1)
        );
        poolManager.initialize(key, activeId, "");

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(poolManager.MAX_BIN_STEP() + 1) // binStep
        });

        vm.expectRevert(
            abi.encodeWithSelector(IBinPoolManager.BinStepTooLarge.selector, poolManager.MAX_BIN_STEP() + 1)
        );
        poolManager.initialize(key, activeId, "");
    }

    function testGasMintOneBin() public {
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 2 ether);
        token1.mint(address(this), 2 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));
        vm.expectEmit();
        bytes32 compositionFee = uint128(0).encode(uint128(0));
        bytes32 pFee = uint128(0).encode(uint128(0));
        emit IBinPoolManager.Mint(key.toId(), address(binLiquidityHelper), ids, 0, amounts, compositionFee, pFee);

        snapStart("BinPoolManagerTest#testGasMintOneBin-1");
        binLiquidityHelper.mint(key, mintParams, "");
        snapEnd();

        // mint on same pool again
        snapStart("BinPoolManagerTest#testGasMintOneBin-2");
        binLiquidityHelper.mint(key, mintParams, "");
        snapEnd();
    }

    function testGasMintNneBins() public {
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        (IBinPoolManager.MintParams memory mintParams,) = _getMultipleBinMintParams(activeId, 2 ether, 2 ether, 5, 5);

        snapStart("BinPoolManagerTest#testGasMintNneBins-1");
        binLiquidityHelper.mint(key, mintParams, "");
        snapEnd();

        snapStart("BinPoolManagerTest#testGasMintNneBins-2");
        binLiquidityHelper.mint(key, mintParams, ""); // cheaper in gas as TreeMath initialized
        snapEnd();
    }

    function testMintNativeCurrency() public {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        poolManager.initialize(key, activeId, new bytes(0));

        token1.mint(address(this), 1 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));
        bytes32 compositionFee = uint128(0).encode(uint128(0));
        bytes32 pFee = uint128(0).encode(uint128(0));
        vm.expectEmit();
        emit IBinPoolManager.Mint(key.toId(), address(binLiquidityHelper), ids, 0, amounts, compositionFee, pFee);

        // 1 ether as add 1 ether in native currency
        snapStart("BinPoolManagerTest#testMintNativeCurrency");
        binLiquidityHelper.mint{value: 1 ether}(key, mintParams, "");
        snapEnd();
    }

    function testMintAndBurnWithSalt() public {
        bytes32 salt = bytes32(uint256(0x1234));
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        (IBinPoolManager.MintParams memory mintParams, uint24[] memory binIds) =
            _getMultipleBinMintParams(activeId, 2 ether, 2 ether, 5, 5, salt);
        binLiquidityHelper.mint(key, mintParams, "");

        // liquidity added with salt 0x1234  not salt 0
        for (uint256 i = 0; i < binIds.length; i++) {
            (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(key.toId(), binIds[i]);

            // make sure the liquidity is added to the correct bin
            if (binIds[i] < activeId) {
                assertEq(binReserveX, 0 ether);
                assertEq(binReserveY, 0.4 ether);
            } else if (binIds[i] > activeId) {
                assertEq(binReserveX, 0.4 ether);
                assertEq(binReserveY, 0 ether);
            } else {
                assertEq(binReserveX, 0.4 ether);
                assertEq(binReserveY, 0.4 ether);
            }

            BinPosition.Info memory position =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt);
            BinPosition.Info memory position0 =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], 0);
            assertTrue(position.share != 0);
            // position with salt = 0
            assertTrue(position0.share == 0);
        }

        // burn liquidity with salt 0x1234
        IBinPoolManager.BurnParams memory burnParams =
            _getMultipleBinBurnLiquidityParams(key, poolManager, binIds, address(binLiquidityHelper), 100, salt);
        binLiquidityHelper.burn(key, burnParams, "");

        for (uint256 i = 0; i < binIds.length; i++) {
            (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(key.toId(), binIds[i]);

            // make sure the liquidity is added to the correct bin
            assertEq(binReserveX, 0 ether);
            assertEq(binReserveY, 0 ether);

            BinPosition.Info memory position =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt);
            BinPosition.Info memory position0 =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], 0);
            assertTrue(position.share == 0);
            assertTrue(position0.share == 0);
        }
    }

    function testMintMixWithAndWithoutSalt() public {
        bytes32 salt0 = bytes32(0);
        bytes32 salt1 = bytes32(uint256(0x1234));
        bytes32 salt2 = bytes32(uint256(0x5678));
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 30 ether);
        token1.mint(address(this), 30 ether);

        (IBinPoolManager.MintParams memory mintParams, uint24[] memory binIds) =
            _getMultipleBinMintParams(activeId, 2 ether, 2 ether, 5, 5, salt1);
        binLiquidityHelper.mint(key, mintParams, "");

        // liquidity added with salt 0x1234  not salt 0
        for (uint256 i = 0; i < binIds.length; i++) {
            (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(key.toId(), binIds[i]);

            // make sure the liquidity is added to the correct bin
            if (binIds[i] < activeId) {
                assertEq(binReserveX, 0 ether);
                assertEq(binReserveY, 0.4 ether);
            } else if (binIds[i] > activeId) {
                assertEq(binReserveX, 0.4 ether);
                assertEq(binReserveY, 0 ether);
            } else {
                assertEq(binReserveX, 0.4 ether);
                assertEq(binReserveY, 0.4 ether);
            }

            BinPosition.Info memory position0 =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt0);
            BinPosition.Info memory position1 =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt1);
            BinPosition.Info memory position2 =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt2);

            // only position with salt 0x1234 should have share
            assertTrue(position0.share == 0);
            assertTrue(position1.share != 0);
            assertTrue(position2.share == 0);
        }

        {
            (mintParams, binIds) = _getMultipleBinMintParams(activeId, 2 ether, 2 ether, 5, 5, salt2);
            binLiquidityHelper.mint(key, mintParams, "");

            for (uint256 i = 0; i < binIds.length; i++) {
                (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(key.toId(), binIds[i]);

                // make sure the liquidity is added to the correct bin
                if (binIds[i] < activeId) {
                    assertEq(binReserveX, 0 ether);
                    assertEq(binReserveY, 0.4 ether * 2);
                } else if (binIds[i] > activeId) {
                    assertEq(binReserveX, 0.4 ether * 2);
                    assertEq(binReserveY, 0 ether);
                } else {
                    assertEq(binReserveX, 0.4 ether * 2);
                    assertEq(binReserveY, 0.4 ether * 2);
                }

                BinPosition.Info memory position0 =
                    poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt0);
                BinPosition.Info memory position1 =
                    poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt1);
                BinPosition.Info memory position2 =
                    poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt2);

                // only position with salt 0 should be empty
                assertTrue(position0.share == 0);
                assertTrue(position1.share != 0);
                assertTrue(position1.share == position2.share);
            }
        }

        {
            (mintParams, binIds) = _getMultipleBinMintParams(activeId, 2 ether, 2 ether, 5, 5, salt0);
            binLiquidityHelper.mint(key, mintParams, "");

            for (uint256 i = 0; i < binIds.length; i++) {
                (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(key.toId(), binIds[i]);

                // make sure the liquidity is added to the correct bin
                if (binIds[i] < activeId) {
                    assertEq(binReserveX, 0 ether);
                    assertEq(binReserveY, 0.4 ether * 3);
                } else if (binIds[i] > activeId) {
                    assertEq(binReserveX, 0.4 ether * 3);
                    assertEq(binReserveY, 0 ether);
                } else {
                    assertEq(binReserveX, 0.4 ether * 3);
                    assertEq(binReserveY, 0.4 ether * 3);
                }

                BinPosition.Info memory position0 =
                    poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt0);
                BinPosition.Info memory position1 =
                    poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt1);
                BinPosition.Info memory position2 =
                    poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt2);

                assertTrue(position0.share != 0);
                assertTrue(position1.share == position0.share);
                assertTrue(position1.share == position2.share);
            }
        }

        // burning liquidity with salt 0x1234 should not impact position0 & position2
        IBinPoolManager.BurnParams memory burnParams =
            _getMultipleBinBurnLiquidityParams(key, poolManager, binIds, address(binLiquidityHelper), 100, salt1);
        binLiquidityHelper.burn(key, burnParams, "");

        for (uint256 i = 0; i < binIds.length; i++) {
            (uint128 binReserveX, uint128 binReserveY,,) = poolManager.getBin(key.toId(), binIds[i]);

            // make sure the liquidity is added to the correct bin
            if (binIds[i] < activeId) {
                assertEq(binReserveX, 0 ether);
                assertEq(binReserveY, 0.4 ether * 2);
            } else if (binIds[i] > activeId) {
                assertEq(binReserveX, 0.4 ether * 2);
                assertEq(binReserveY, 0 ether);
            } else {
                assertEq(binReserveX, 0.4 ether * 2);
                assertEq(binReserveY, 0.4 ether * 2);
            }

            BinPosition.Info memory position0 =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt0);
            BinPosition.Info memory position1 =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt1);
            BinPosition.Info memory position2 =
                poolManager.getPosition(key.toId(), address(binLiquidityHelper), binIds[i], salt2);

            assertTrue(position0.share != 0);
            assertTrue(position1.share == 0);
            assertTrue(position0.share == position2.share);
        }
    }

    function testGasBurnOneBin() public {
        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 2 ether);
        token1.mint(address(this), 2 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 100);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));
        vm.expectEmit();
        emit IBinPoolManager.Burn(key.toId(), address(binLiquidityHelper), ids, 0, amounts);

        snapStart("BinPoolManagerTest#testGasBurnOneBin");
        binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
    }

    function testGasBurnHalfBin() public {
        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 2 ether);
        token1.mint(address(this), 2 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 50);

        snapStart("BinPoolManagerTest#testGasBurnHalfBin");
        binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
    }

    function testGasBurnNineBins() public {
        poolManager.initialize(key, activeId, new bytes(0));

        // mint on 9 bins
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        (IBinPoolManager.MintParams memory mintParams, uint24[] memory binIds) =
            _getMultipleBinMintParams(activeId, 10 ether, 10 ether, 5, 5);
        binLiquidityHelper.mint(key, mintParams, "");

        // burn on 9 binds
        IBinPoolManager.BurnParams memory burnParams =
            _getMultipleBinBurnLiquidityParams(key, poolManager, binIds, address(binLiquidityHelper), 100);
        snapStart("BinPoolManagerTest#testGasBurnNineBins");
        binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
    }

    function testBurnNativeCurrency() public {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token1.mint(address(this), 1 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint{value: 1 ether}(key, mintParams, "");

        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 100);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));
        vm.expectEmit();
        emit IBinPoolManager.Burn(key.toId(), address(binLiquidityHelper), ids, 0, amounts);

        snapStart("BinPoolManagerTest#testBurnNativeCurrency");
        binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
    }

    function testGasSwapSingleBin() public {
        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 10 ether, 10 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // swap 1 ether of tokenX for tokenY
        token0.mint(address(this), 1 ether);
        BinSwapHelper.TestSettings memory testSettings =
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        vm.expectEmit();
        emit IBinPoolManager.Swap(
            key.toId(), address(binSwapHelper), -1 ether, (1 ether * 997) / 1000, activeId, key.fee, 0
        );

        snapStart("BinPoolManagerTest#testGasSwapSingleBin");
        binSwapHelper.swap(key, true, -int128(1 ether), testSettings, "");
        snapEnd();
    }

    function testGasSwapMultipleBins() public {
        poolManager.initialize(key, activeId, new bytes(0));

        // mint on 9 bins, around 2 eth worth on each bin. eg. 4 binY || activeBin || 4 binX
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        (IBinPoolManager.MintParams memory mintParams,) = _getMultipleBinMintParams(activeId, 10 ether, 10 ether, 5, 5);
        binLiquidityHelper.mint(key, mintParams, "");

        // swap 8 ether of tokenX for tokenY
        token0.mint(address(this), 8 ether);
        BinSwapHelper.TestSettings memory testSettings =
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        snapStart("BinPoolManagerTest#testGasSwapMultipleBins");
        binSwapHelper.swap(key, true, -int128(8 ether), testSettings, ""); // traverse over 4 bin
        snapEnd();
    }

    function testGasSwapOverBigBinIdGate() public {
        poolManager.initialize(key, activeId, new bytes(0));

        // mint on 9 bins, around 2 eth worth on each bin. eg. 4 binY || activeBin || 4 binX
        token0.mint(address(this), 1 ether);
        token1.mint(address(this), 6 ether);

        IBinPoolManager.MintParams memory mintParams;

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // add 5 eth of tokenY liquidity.
        for (uint256 i = 1; i < 6; i++) {
            mintParams = _getCustomSingleSidedBinMintParam(activeId - uint24(300 * i), 1 ether, true);
            binLiquidityHelper.mint(key, mintParams, "");
        }

        // swap 6 ether of tokenX for tokenY. crossing over 5
        token0.mint(address(this), 6 ether);
        BinSwapHelper.TestSettings memory testSettings =
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        snapStart("BinPoolManagerTest#testGasSwapOverBigBinIdGate");
        binSwapHelper.swap(key, true, -int128(6 ether), testSettings, "");
        snapEnd();
    }

    function testGasDonate() public {
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 11 ether);
        token1.mint(address(this), 11 ether);

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        vm.expectEmit();
        emit IBinPoolManager.Donate(key.toId(), address(binDonateHelper), -10 ether, -10 ether, activeId);

        snapStart("BinPoolManagerTest#testGasDonate");
        binDonateHelper.donate(key, 10 ether, 10 ether, "");
        snapEnd();
    }

    function testSwapUseSurplusTokenAsInput() public {
        BinSwapHelper.TestSettings memory testSettings;

        // initialize the pool
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 10 ether, 10 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // step 1: swap from currency0 to currency1 -- take tokenOut as NFT
        token0.mint(address(this), 1 ether);
        testSettings = BinSwapHelper.TestSettings({withdrawTokens: false, settleUsingTransfer: true});
        binSwapHelper.swap(key, true, -int128(1 ether), testSettings, "");

        // step 2: verify surplus token balance
        uint256 surplusTokenAmount = vault.balanceOf(address(this), currency1);
        assertEq(surplusTokenAmount, 997 * 1e15); // 0.3% fee. amt: 997 * 1e15

        // Step 3: swap from currency1 to currency0, take takenIn from existing NFT
        vault.approve(address(binSwapHelper), currency1, type(uint256).max);
        testSettings = BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: false});
        binSwapHelper.swap(key, false, -int128(1e17), testSettings, "");

        // Step 4: Verify surplus token balance used as input
        surplusTokenAmount = vault.balanceOf(address(this), currency1);
        assertEq(surplusTokenAmount, 897 * 1e15);
    }

    function testMintPoolNotInitialized() public {
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 10 ether, 10 ether);

        vm.expectRevert(PoolNotInitialized.selector);
        binLiquidityHelper.mint(key, mintParams, "");
    }

    function testBurnPoolNotInitialized() public {
        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 100);

        vm.expectRevert(PoolNotInitialized.selector);
        binLiquidityHelper.burn(key, burnParams, "");
    }

    function testSwapPoolNotInitialized() public {
        BinSwapHelper.TestSettings memory testSettings;

        token0.mint(address(this), 1 ether);
        testSettings = BinSwapHelper.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        vm.expectRevert(PoolNotInitialized.selector);
        binSwapHelper.swap(key, true, -int128(1 ether), testSettings, "");
    }

    function testDonatePoolNotInitialized() public {
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);

        vm.expectRevert(PoolNotInitialized.selector);
        binDonateHelper.donate(key, 10 ether, 10 ether, "");
    }

    /*
    function testExtLoadPoolActiveId() public {
        // verify owner at slot 0
        bytes32 owner = poolManager.extsload(0x00);
        assertEq(abi.encode(owner), abi.encode(address(this)));

        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // verify poolId.
        uint256 POOL_SLOT = 4;
        snapStart("BinPoolManagerTest#testExtLoadPoolActiveId");
        bytes32 slot0Bytes = poolManager.extsload(keccak256(abi.encode(key.toId(), POOL_SLOT)));
        snapEnd();

        uint24 ativeIdExtsload;
        assembly {
            // slot0Bytes: 0x0000000000000000000000000000000000000000000000000000000000800000
            ativeIdExtsload := slot0Bytes
        }
        (uint24 activeIdLoad,,) = poolManager.getSlot0(key.toId());

        // assert that extsload loads the correct storage slot which matches the true slot0
        assertEq(ativeIdExtsload, activeIdLoad);
    }
    */

    function testSetProtocolFeePoolNotOwner() public {
        MockProtocolFeeController feeController = new MockProtocolFeeController();
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));

        uint24 protocolFee = feeController.protocolFeeForPool(key);

        vm.expectRevert(IProtocolFees.InvalidCaller.selector);
        poolManager.setProtocolFee(key, protocolFee);
    }

    function testSetProtocolFeePoolNotInitialized() public {
        MockProtocolFeeController feeController = new MockProtocolFeeController();
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));

        uint24 protocolFee = feeController.protocolFeeForPool(key);

        vm.expectRevert(PoolNotInitialized.selector);
        vm.prank(address(feeController));
        poolManager.setProtocolFee(key, protocolFee);
    }

    function testSetProtocolFee() public {
        // initialize the pool and asset protocolFee is 0
        poolManager.initialize(key, activeId, new bytes(0));
        (, uint24 protocolFee,) = poolManager.getSlot0(key.toId());
        assertEq(protocolFee, 0);

        // set up feeController
        MockProtocolFeeController feeController = new MockProtocolFeeController();
        uint24 newProtocolFee = _getSwapFee(1000, 1000); // 0.1%
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));

        // Call setProtocolFee, verify event and state updated
        vm.expectEmit();
        emit ProtocolFeeUpdated(key.toId(), newProtocolFee);
        snapStart("BinPoolManagerTest#testSetProtocolFee");
        vm.prank(address(feeController));
        poolManager.setProtocolFee(key, newProtocolFee);
        snapEnd();

        (, protocolFee,) = poolManager.getSlot0(key.toId());
        assertEq(protocolFee, newProtocolFee);
    }

    function testFuzz_SetMaxBinStep(uint16 binStep) public {
        vm.assume(binStep > poolManager.MIN_BIN_STEP());

        vm.expectEmit();
        emit SetMaxBinStep(binStep);
        poolManager.setMaxBinStep(binStep);

        assertEq(poolManager.MAX_BIN_STEP(), binStep);
    }

    function testGas_SetMaxBinStep() public {
        uint16 binStep = 10;

        vm.expectEmit();
        emit SetMaxBinStep(binStep);
        snapStart("BinPoolManagerTest#testFuzz_SetMaxBinStep");
        poolManager.setMaxBinStep(binStep);
        snapEnd();

        assertEq(poolManager.MAX_BIN_STEP(), binStep);
    }

    function testSetMaxBinStep() public {
        uint16 binStep = 0;
        vm.expectRevert(abi.encodeWithSelector(MaxBinStepTooSmall.selector, binStep));
        poolManager.setMaxBinStep(binStep);

        vm.prank(makeAddr("bob"));
        vm.expectRevert();
        poolManager.setMaxBinStep(100);
    }

    function testFuzz_SetMinBinSharesForDonate(uint256 minShare) public {
        minShare = bound(minShare, 1e18, type(uint256).max);

        vm.expectEmit();
        emit IBinPoolManager.SetMinBinSharesForDonate(minShare);
        poolManager.setMinBinSharesForDonate(minShare);

        assertEq(poolManager.MIN_BIN_SHARE_FOR_DONATE(), minShare);
    }

    function testMinBinSharesForDonate_OnlyOwner() public {
        vm.prank(makeAddr("bob"));
        vm.expectRevert();
        poolManager.setMinBinSharesForDonate(1e18);
    }

    function testUpdateDynamicLPFee_FeeTooLarge() public {
        uint16 bitMap = 0x0004; // 0000 0000 0000 0100 (before mint call)
        BinFeeManagerHook binFeeManagerHook = new BinFeeManagerHook(poolManager);
        binFeeManagerHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(binFeeManagerHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(bitMap)).setBinStep(10)
        });

        binFeeManagerHook.setFee(LPFeeLibrary.TEN_PERCENT_FEE + 1);

        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, LPFeeLibrary.TEN_PERCENT_FEE + 1));
        vm.prank(address(binFeeManagerHook));
        poolManager.updateDynamicLPFee(key, LPFeeLibrary.TEN_PERCENT_FEE + 1);
    }

    function testUpdateDynamicLPFee_FeeNotDynamic() public {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam
        });

        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        poolManager.updateDynamicLPFee(key, 3000);
    }

    function testFuzzUpdateDynamicLPFee(uint24 _lpFee) public {
        _lpFee = uint24(bound(_lpFee, 0, LPFeeLibrary.TEN_PERCENT_FEE));

        uint16 bitMap = 0x0004; // 0000 0000 0000 0100 (before mint call)
        BinFeeManagerHook binFeeManagerHook = new BinFeeManagerHook(poolManager);
        binFeeManagerHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(binFeeManagerHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(bitMap)).setBinStep(10)
        });
        poolManager.initialize(key, activeId, new bytes(0));

        binFeeManagerHook.setFee(_lpFee);

        vm.expectEmit();
        emit DynamicLPFeeUpdated(key.toId(), _lpFee);

        vm.prank(address(binFeeManagerHook));
        poolManager.updateDynamicLPFee(key, _lpFee);

        (,, uint24 swapFee) = poolManager.getSlot0(key.toId());
        assertEq(swapFee, _lpFee);
    }

    function testGasUpdateDynamicLPFee() public {
        uint24 _lpFee = LPFeeLibrary.TEN_PERCENT_FEE / 2;

        uint16 bitMap = 0x0004; // 0000 0000 0000 0100 (before mint call)
        BinFeeManagerHook binFeeManagerHook = new BinFeeManagerHook(poolManager);
        binFeeManagerHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(binFeeManagerHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(bitMap)).setBinStep(10)
        });
        poolManager.initialize(key, activeId, new bytes(0));

        binFeeManagerHook.setFee(_lpFee);

        vm.expectEmit();
        emit DynamicLPFeeUpdated(key.toId(), _lpFee);

        vm.prank(address(binFeeManagerHook));
        snapStart("BinPoolManagerTest#testFuzzUpdateDynamicLPFee");
        poolManager.updateDynamicLPFee(key, _lpFee);
        snapEnd();

        (,, uint24 swapFee) = poolManager.getSlot0(key.toId());
        assertEq(swapFee, _lpFee);
    }

    function testSwap_WhenPaused() public {
        BinSwapHelper.TestSettings memory testSettings;

        // initialize the pool
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 10 ether, 10 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // pause
        poolManager.pause();

        // attempt swap
        token0.mint(address(this), 1 ether);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        testSettings = BinSwapHelper.TestSettings({withdrawTokens: false, settleUsingTransfer: true});
        binSwapHelper.swap(key, true, -int128(1 ether), testSettings, "");
    }

    function testMint_WhenPaused() public {
        token0.mint(address(this), 1 ether);
        token1.mint(address(this), 1 ether);

        poolManager.initialize(key, activeId, new bytes(0));
        IBinPoolManager.MintParams memory mintParams;

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);

        // pause
        poolManager.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        binLiquidityHelper.mint(key, mintParams, "");
    }

    // verify remove liquidity is fine when paused
    function testBurn_WhenPaused() public {
        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 2 ether);
        token1.mint(address(this), 2 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // pause
        poolManager.pause();

        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 100);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));

        // verify no issue even when pause
        binLiquidityHelper.burn(key, burnParams, "");
    }

    function testDonate_WhenPaused() public {
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 11 ether);
        token1.mint(address(this), 11 ether);

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // pause
        poolManager.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        binDonateHelper.donate(key, 10 ether, 10 ether, "");
    }

    function testGasGetBin() public {
        // Initialize and add 1e18 token0, token1 to the active bin. price of bin: 2**128, 3.4e38
        poolManager.initialize(key, activeId, new bytes(0));

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        token0.mint(address(this), 1 ether);
        token1.mint(address(this), 1 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        snapStart("BinPoolManagerTest#testGasGetBin");
        (uint128 reserveX, uint128 reserveY, uint256 liquidity, uint256 shares) =
            poolManager.getBin(key.toId(), activeId);
        snapEnd();

        assertEq(reserveX, 1e18);
        assertEq(reserveY, 1e18);

        bytes32 binReserves = reserveX.encode(reserveY);
        uint16 binStep = key.parameters.getBinStep();
        uint256 binLiquidity = binReserves.getLiquidity(activeId.getPriceFromId(binStep));
        assertEq(liquidity, binLiquidity);
        assertEq(shares, liquidity);
    }

    receive() external payable {}

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function _getSwapFee(uint24 fee0, uint24 fee1) internal pure returns (uint24) {
        return fee0 + (fee1 << 12);
    }
}
