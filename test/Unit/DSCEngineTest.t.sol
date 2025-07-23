// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "../Mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    event collateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_TO_REDEEM = 7 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 20 ether;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////////
    // constructor Test     //
    /////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__tokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ////////////////////
    // Price Test     //
    ////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;

        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmountInWei = 1000e18;

        uint256 expectedweth = 0.5e18;
        uint256 actualweth = dsce.getTokenAmountFromUsd(weth, usdAmountInWei);
        assertEq(expectedweth, actualweth);
    }

    //////////////////////////////////
    // Deposit Collateral Test   /////
    /////////////////////////////////

    function testRevertIfCollateralIsZero() public {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__notAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testDsceEmitsEventOnDepositingCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, false, address(dsce));
        emit collateralDeposited(USER, weth, AMOUNT_COLLATERAL);

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    //////////////////////////////////
    // liqudate Test   /////
    /////////////////////////////////

    function testRevertIfHealthFactorIsOk() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(1e18);
        uint256 startingUserHealthFactor = dsce.getHealthFactor(USER);

        uint256 expectedHealthFactor = MIN_HEALTH_FACTOR;
        assertGt(startingUserHealthFactor, expectedHealthFactor);
        vm.expectRevert(DSCEngine.DSCEngine__healthFactorOk.selector);
        dsce.liquidate(weth, USER, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // Since the liquidate function is expected to work if and only if, the users healthFactor is in danger. We've tested for the fool proof, if the healthfactor is still high this function can't be called it will revert an error "DsceEngine__HealthIsOk". So, the next possible test to carry out now is assuming the healthFactor of the user is low will this function work, but before doing that we should write test cases for the units that makes up the function. I will be starting with redeem function.

    function testIfTheCollateralIsRedeemable() public depositedCollateral {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_TO_REDEEM);
        dsce.redeemCollateral(weth, AMOUNT_TO_REDEEM);
        vm.stopPrank();
    }

    // Next is burnDsc
    function testIfBurnDscImprovesUserHealthFactor() public depositedCollateral {
        vm.startPrank(USER);

        // First mint some DSC to create debt
        dsce.mintDsc(2e18);

        // Get initial health factor (should be lower due to debt)
        uint256 initialHealthFactor = dsce.getHealthFactor(USER);

        // Approve DSC Engine to spend DSC tokens for burning
        dsc.approve(address(dsce), 1e18); // or whatever your DSC token variable is

        // Burn some DSC to reduce debt
        dsce.burnDsc(1e18);

        // Get final health factor (should be higher after reducing debt)
        uint256 finalUserHealthFactor = dsce.getHealthFactor(USER);

        // Assert that burning DSC improved the health factor
        assertGt(finalUserHealthFactor, initialHealthFactor);

        vm.stopPrank();
    }

    /*function testRevertIfHealthFactorIsBroken() public depositedCollateral {
        vm.startPrank(USER);
        uint256 safeBorrowLimit = (AMOUNT_COLLATERAL * LIQUIDATION_THRESHOLD) /
            100;
        dsce.mintDsc(safeBorrowLimit);
        vm.stopPrank();

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(1000e8);
        uint256 expectedHealthFactor = dsce.getHealthFactor(USER);
        console.log("USER HEALTH FACTOR:", expectedHealthFactor);

        assertLt(expectedHealthFactor, MIN_HEALTH_FACTOR);
        vm.expectRevert(DSCEngine.DSCEngine__breaksHealthFactor.selector);
        dsce.callRevertIfHealthFactorIsBroken(USER);
    }
    */
}
