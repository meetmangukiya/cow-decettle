pragma solidity 0.8.26;

import {SubPoolFactory, Auth} from "src/SubPoolFactory.sol";
import {MockToken} from "./MockToken.sol";
import {TOKEN_WETH_MAINNET, CHAINLINK_PRICE_FEED_WETH_MAINNET, TOKEN_COW_MAINNET} from "src/constants.sol";
import {BaseTest} from "./BaseTest.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract SubPoolFactoryTest is BaseTest {
    MockToken lst = new MockToken("LST", "ether");
    address solver = makeAddr("solver");
    address solverPoolAddress;
    uint256 solverEthAmt = 20 ether;
    address notRelied = makeAddr("notRelied");

    function setUp() public override {
        super.setUp();

        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 3500e8);

        deal(TOKEN_WETH_MAINNET, solver, solverEthAmt);
        deal(TOKEN_COW_MAINNET, solver, minCowAmt);
        vm.startPrank(solver);
        ERC20(TOKEN_WETH_MAINNET).approve(address(factory), solverEthAmt);
        ERC20(TOKEN_COW_MAINNET).approve(address(factory), minCowAmt);
        solverPoolAddress = factory.create(TOKEN_WETH_MAINNET, solverEthAmt, minCowAmt);
        vm.stopPrank();
    }

    function testAllowCollateral() external {
        address token = makeAddr("token");
        vm.expectRevert(SubPoolFactory.SubPoolFactory__InvalidPriceFeed.selector);
        factory.allowCollateral(token, address(0));

        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        vm.prank(notRelied);
        factory.allowCollateral(token, address(0));
    }

    function testRevokeCollateral() external {
        vm.prank(notRelied);
        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        factory.revokeCollateral(TOKEN_WETH_MAINNET);

        factory.revokeCollateral(TOKEN_WETH_MAINNET);
        assertEq(address(factory.priceFeeds(TOKEN_WETH_MAINNET)), address(0), "didnt revoke as expected");
    }

    function testCreate() external {
        address user = makeAddr("user");

        // if < min cow, revert
        vm.expectRevert(SubPoolFactory.SubPoolFactory__InsufficientCollateral.selector);
        vm.prank(user);
        factory.create(TOKEN_WETH_MAINNET, 100 ether, minCowAmt - 1);

        // if collateral < minUsd, revert
        vm.expectRevert(SubPoolFactory.SubPoolFactory__InsufficientCollateral.selector);
        vm.prank(user);
        factory.create(TOKEN_WETH_MAINNET, 0.1 ether, minCowAmt);

        // if amts are correct, but user doesnt have the tokens, revert
        vm.expectRevert();
        vm.prank(user);
        factory.create(TOKEN_WETH_MAINNET, 15 ether, minCowAmt);

        // give tokens to the user
        deal(TOKEN_WETH_MAINNET, user, 15 ether);
        deal(TOKEN_COW_MAINNET, user, minCowAmt);
        vm.startPrank(user);
        ERC20(TOKEN_WETH_MAINNET).approve(address(factory), 15 ether);
        ERC20(TOKEN_COW_MAINNET).approve(address(factory), minCowAmt);
        factory.create(TOKEN_WETH_MAINNET, 15 ether, minCowAmt);
        vm.stopPrank();

        (address collateral, uint104 exitTimestamp, uint104 freezeTimestamp, bool isFrozen, bool isExited) =
            factory.subPoolData(solverPoolAddress);
        assertEq(collateral, TOKEN_WETH_MAINNET, "collateral not as expected");
        assertEq(exitTimestamp, 0, "exit timestamp should be initialized to 0");
        assertEq(freezeTimestamp, 0, "freeze timestamp should be initialized to 0");
        assertEq(isFrozen, false, "pool shouldnt be frozen at initialization");
        assertEq(isExited, false, "pool shouldnt be exited at initialization");
    }

    function testPoolOf() external view {
        address expectedSolverPool = factory.poolOf(solver);
        assertEq(expectedSolverPool, solverPoolAddress, "solver pool address not as expected");
    }

    function testDues() external {
        (uint256 tokenDues, uint256 cowDues) = factory.dues(solverPoolAddress);
        assertEq(tokenDues, 0, "token dues not 0");
        assertEq(cowDues, 0, "cow dues not 0");

        // slash some cow
        uint256 slashedCowAmt = 10;
        factory.fine(solverPoolAddress, 0, slashedCowAmt);
        (tokenDues, cowDues) = factory.dues(solverPoolAddress);
        assertEq(tokenDues, 0, "token dues not 0");
        assertEq(cowDues, slashedCowAmt, "cow dues not as expected");

        // plunge the eth price
        uint256 newPrice = 2000e8;
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 2000e8);
        (tokenDues, cowDues) = factory.dues(solverPoolAddress);
        uint256 expectedTokenDue = (minUsdAmt - (solverEthAmt * newPrice / 1 ether)) * 1 ether / (newPrice);
        assertEq(tokenDues, expectedTokenDue, "token dues not as expected");
        assertEq(cowDues, slashedCowAmt, "cow dues not as expected");

        // all dues should be 0 after a pool quits
        vm.prank(solverPoolAddress);
        factory.quitPool();
        (tokenDues, cowDues) = factory.dues(solverPoolAddress);
        assertEq(tokenDues, 0, "token dues not 0 after quit");
        assertEq(cowDues, 0, "cow dues not 0 after exit");
    }

    function testFine() external {
        // only relied users can fine
        vm.prank(notRelied);
        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        factory.fine(solverPoolAddress, 1 ether, 10000 ether);

        uint256 wethBalanceBefore = weth.balanceOf(address(this));
        uint256 cowBalanceBefore = cow.balanceOf(address(this));
        uint256 wethFined = 0.1 ether;
        factory.fine(solverPoolAddress, wethFined, 0);

        assertEq(weth.balanceOf(address(this)) - wethBalanceBefore, wethFined, "weth not fined as expected");
        assertEq(cow.balanceOf(address(this)) - cowBalanceBefore, 0, "cow not fined as expected");
        (,, uint104 freezeTimestamp, bool isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(freezeTimestamp, 0, "pool shouldn't have been poked yet");
        assertEq(isFrozen, false, "pool shouldn't be frozen");

        // fine 1 cow, will make it pokable
        factory.fine(solverPoolAddress, 0, 1);
        assertEq(cow.balanceOf(address(this)) - cowBalanceBefore, 1, "cow not fined as expected");
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(freezeTimestamp, block.timestamp + freezeDelay, "freeze timestamp not as expected");
        assertEq(isFrozen, false, "pool shouldn't be frozen");

        // send the 1 cow back
        cow.transfer(solverPoolAddress, 1);
        factory.thaw(solverPoolAddress);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(freezeTimestamp, 0, "freeze timestamp not 0 after thaw");

        // fine significant eth, should make it pokable again
        wethBalanceBefore = weth.balanceOf(address(this));
        wethFined = 10 ether;
        factory.fine(solverPoolAddress, wethFined, 0);
        assertEq(weth.balanceOf(address(this)) - wethBalanceBefore, wethFined, "weth not fined as expected");
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(freezeTimestamp, block.timestamp + freezeDelay, "freeze timestamp not as expected");
        assertEq(isFrozen, false, "pool shouldn't be frozen");
    }

    function testFreeze() external {
        (,, uint104 freezeTimestamp, bool isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(freezeTimestamp, 0, "pool shouldn't have been poked yet");
        assertEq(isFrozen, false, "pool shouldn't be frozen");

        // plunge eth price
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 2000e8);
        factory.poke(solverPoolAddress);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(freezeTimestamp, block.timestamp + freezeDelay, "freezeTiemstamp not as expected");
        assertEq(isFrozen, false, "pool shouldn't be frozen");

        // forward time, but not enough
        vm.warp(freezeTimestamp - 1);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__FreezeTimestampNotElapsedYet.selector);
        factory.freeze(solverPoolAddress);

        // forward time, also verify that anyone can freeze anyone
        vm.warp(freezeTimestamp);
        vm.prank(notRelied);
        factory.freeze(solverPoolAddress);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(freezeTimestamp, 0, "freezeTimestamp should reset to 0");
        assertEq(isFrozen, true, "pool is not frozen");
    }

    function testPoke() external {
        vm.expectRevert(SubPoolFactory.SubPoolFactory__CannotPoke.selector);
        factory.poke(solverPoolAddress);

        // plunge eth price
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 2000e8);
        // anyone should be able to poke anyone
        vm.prank(notRelied);
        factory.poke(solverPoolAddress);
        (,, uint104 freezeTimestamp, bool isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(isFrozen, false, "pool shouldn't be frozen yet");
        assertEq(freezeTimestamp, block.timestamp + freezeDelay, "freezeTimestamp not as expected");

        // reset eth price back to normal
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 3000e8);
        factory.thaw(solverPoolAddress);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(isFrozen, false, "pool shouldnt be frozen");
        assertEq(freezeTimestamp, 0, "freezeTimestamp is not 0");

        // fine 1 cow, should autopoke
        factory.fine(solverPoolAddress, 0, 1);
        vm.prank(notRelied);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(isFrozen, false, "pool shouldnt be frozen");
        assertEq(freezeTimestamp, block.timestamp + freezeDelay, "freezeTimestamp not as expected");
    }

    function testThaw() external {
        // plunge eth price
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 2000e8);
        factory.poke(solverPoolAddress);
        (,, uint104 freezeTimestamp, bool isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(isFrozen, false, "pool shouldnt be frozen");
        assertEq(freezeTimestamp, block.timestamp + freezeDelay, "freezeTimestamp is not as expected");

        // try to thaw even though nothing has changed
        vm.prank(notRelied);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__CannotThaw.selector);
        factory.thaw(solverPoolAddress);

        // eth price back to normal, also verify that anyone can thaw anyone
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 3500e8);
        vm.prank(notRelied);
        factory.thaw(solverPoolAddress);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(isFrozen, false, "pool shouldnt be frozen");
        assertEq(freezeTimestamp, 0, "freezeTimestamp is not 0");

        // plunge eth price again, also freeze it this time, verify that thaw restores frozen status too
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 2000e8);
        factory.poke(solverPoolAddress);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        vm.warp(freezeTimestamp);
        factory.freeze(solverPoolAddress);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(isFrozen, true, "pool should be frozen");
        assertEq(freezeTimestamp, 0, "freezeTimestamp is not 0");

        // eth price back to normal
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 3500e8);
        factory.thaw(solverPoolAddress);
        (,, freezeTimestamp, isFrozen,) = factory.subPoolData(solverPoolAddress);
        assertEq(isFrozen, false, "pool shouldnt be frozen after thaw");
        assertEq(freezeTimestamp, 0, "freezeTimestamp should be 0 after thaw");
    }

    function testSetExitDelay() external {
        vm.prank(notRelied);
        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        factory.setExitDelay(1);

        factory.setExitDelay(1);
        (uint24 exitDelay,,,) = factory.cfg();
        assertEq(exitDelay, 1, "exit delay not set as expected");
    }

    function testSetFreezeDelay() external {
        vm.prank(notRelied);
        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        factory.setFreezeDelay(1);

        factory.setFreezeDelay(1);
        (, uint24 freezeDelay,,) = factory.cfg();
        assertEq(freezeDelay, 1, "freeze delay not set as expected");
    }

    function testSetMinCowAmt() external {
        vm.prank(notRelied);
        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        factory.setMinCowAmt(1);

        factory.setMinCowAmt(1);
        (,, uint104 minCowAmt,) = factory.cfg();
        assertEq(minCowAmt, 1, "min cow amt not set as expected");
    }

    function testSetMinUsdAmt() external {
        vm.prank(notRelied);
        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        factory.setMinUsdAmt(1);

        factory.setMinUsdAmt(1);
        (,,, uint104 minUsdAmt) = factory.cfg();
        assertEq(minUsdAmt, 1, "min usd amt not set as expected");
    }

    function testExitTimestamp() external {
        assertEq(factory.exitTimestamp(solverPoolAddress), 0, "pool hasnt quit yet");

        // quit the pool
        vm.prank(solverPoolAddress);
        factory.quitPool();
        uint256 exitTs = block.timestamp + exitDelay;
        assertEq(factory.exitTimestamp(solverPoolAddress), exitTs, "exit timestamp not as expected");

        // exit the pool, verify the exit timestamp doesnt change even on exit
        vm.warp(exitTs);
        vm.prank(solverPoolAddress);
        factory.exitPool();
        assertEq(factory.exitTimestamp(solverPoolAddress), exitTs, "exit timestamp not as expected");
    }

    function testQuitPool() external {
        // addresses not spawned by the factory's create method shouldn't be able to
        // call quit pool
        vm.prank(notRelied);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.quitPool();

        assertEq(factory.exitTimestamp(solverPoolAddress), 0, "no exit timestamp before quit");
        vm.prank(solverPoolAddress);
        factory.quitPool();
        assertEq(
            factory.exitTimestamp(solverPoolAddress), block.timestamp + exitDelay, "exit timestamp not set by quit"
        );

        // pool cannot quit twice
        vm.prank(solverPoolAddress);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__PoolAlreadyQuit.selector);
        factory.quitPool();
    }

    function testExitPool() external {
        // addresses not spawned by the factory's create method shouldn't be able to
        // call exit pool
        vm.prank(notRelied);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.exitPool();

        // try to exit without quit
        vm.prank(solverPoolAddress);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__PoolHasNotQuitYet.selector);
        factory.exitPool();

        // exit time not elapsed
        vm.startPrank(solverPoolAddress);
        factory.quitPool();
        vm.expectRevert(SubPoolFactory.SubPoolFactory__ExitDelayNotElapsed.selector);
        factory.exitPool();
        vm.stopPrank();

        uint256 exitTs = factory.exitTimestamp(solverPoolAddress);
        vm.warp(exitTs);
        vm.prank(solverPoolAddress);
        factory.exitPool();
        (,,,, bool hasExited) = factory.subPoolData(solverPoolAddress);
        assertEq(hasExited, true, "pool not marked exited");

        // try to exit again, should fail
        vm.prank(solverPoolAddress);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__PoolAlreadyExited.selector);
        factory.exitPool();
    }

    function testIsSolver() external {
        assertEq(factory.isSolver(solverPoolAddress), true, "pool should be a solver");

        // plunge eth price and poke, poked pools should still be solvers
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 2000e8);
        factory.poke(solverPoolAddress);
        assertEq(factory.isSolver(solverPoolAddress), true, "pool shouldnt be a solver after being poked");

        // forward time and freeze
        vm.warp(block.timestamp + freezeDelay);
        factory.freeze(solverPoolAddress);
        assertEq(factory.isSolver(solverPoolAddress), false, "frozen pool shouldnt be a solver");

        // recover eth price, thaw
        _mockChainlinkPrice(TOKEN_WETH_MAINNET, 3500e8);
        factory.thaw(solverPoolAddress);
        assertEq(factory.isSolver(solverPoolAddress), true, "thawed pool should be a solver");

        // quit pool
        vm.prank(solverPoolAddress);
        factory.quitPool();
        assertEq(factory.isSolver(solverPoolAddress), false, "quited pools shouldnt be a solver");
    }
}
