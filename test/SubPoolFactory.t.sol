pragma solidity 0.8.26;

import {SubPoolFactory, Auth, SubPool} from "src/SubPoolFactory.sol";
import {MockToken} from "./MockToken.sol";
import {TOKEN_WETH_MAINNET, CHAINLINK_PRICE_FEED_WETH_MAINNET, TOKEN_COW_MAINNET} from "src/constants.sol";
import {BaseTest} from "./BaseTest.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract SubPoolFactoryTest is BaseTest {
    MockToken lst = new MockToken("LST", "ether");
    address solver = makeAddr("solver");
    address solverPoolAddress;
    uint256 solverEthAmt = 20 ether;
    SubPool solverPool;
    address notOwner = makeAddr("notOwner");
    string backendUri = "https://backend.solver.com";

    function setUp() public override {
        super.setUp();

        deal(TOKEN_WETH_MAINNET, solver, solverEthAmt);
        deal(TOKEN_COW_MAINNET, solver, minCowAmt);
        vm.startPrank(solver);
        ERC20(TOKEN_WETH_MAINNET).approve(address(factory), solverEthAmt);
        ERC20(TOKEN_COW_MAINNET).approve(address(factory), minCowAmt);
        solverPoolAddress = factory.create(TOKEN_WETH_MAINNET, solverEthAmt, minCowAmt, backendUri);
        solverPool = SubPool(solverPoolAddress);
        vm.stopPrank();
    }

    function testCreate() external {
        address user = makeAddr("user");

        // if < min cow, revert
        vm.expectRevert(SubPoolFactory.SubPoolFactory__InsufficientCollateral.selector);
        vm.prank(user);
        factory.create(TOKEN_WETH_MAINNET, 1, minCowAmt - 1, backendUri);

        // if amts are correct, but user doesnt have the tokens, revert
        vm.expectRevert();
        vm.prank(user);
        factory.create(TOKEN_WETH_MAINNET, 15 ether, minCowAmt, backendUri);

        // give tokens to the user
        deal(TOKEN_WETH_MAINNET, user, 15 ether);
        deal(TOKEN_COW_MAINNET, user, minCowAmt);
        vm.startPrank(user);
        ERC20(TOKEN_WETH_MAINNET).approve(address(factory), 15 ether);
        ERC20(TOKEN_COW_MAINNET).approve(address(factory), minCowAmt);
        factory.create(TOKEN_WETH_MAINNET, 15 ether, minCowAmt, backendUri);
        vm.stopPrank();

        (address collateral, uint88 exitTimestamp, bool isExited) = factory.subPoolData(solverPoolAddress);
        assertEq(collateral, TOKEN_WETH_MAINNET, "collateral not as expected");
        assertEq(exitTimestamp, 0, "exit timestamp should be initialized to 0");
        assertEq(isExited, false, "pool shouldnt be exited at initialization");
        assertEq(factory.backendUri(solverPoolAddress), backendUri, "solver backend uri not set at initialization");
    }

    function testPoolOf() external view {
        address expectedSolverPool = factory.poolOf(solver);
        assertEq(expectedSolverPool, solverPoolAddress, "solver pool address not as expected");
    }

    function testSubPool() external {
        address expectedSolverPool = factory.solverSubPool(solver);
        assertEq(expectedSolverPool, solverPoolAddress, "solver pool address not as expected");
        address anotherSolver = makeAddr("anotherSolver");
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.solverSubPool(anotherSolver);
    }

    function testSubPoolData() external {
        (address collateral, uint88 exitTs, bool hasExited) = factory.subPoolData(solverPoolAddress);
        assertEq(collateral, TOKEN_WETH_MAINNET, "collateral not as expected");
        assertEq(exitTs, 0, "exit timestamp not as expected");
        assertEq(hasExited, false, "hasExited not as expected");

        vm.prank(solver);
        solverPool.announceExit();
        (, exitTs, hasExited) = factory.subPoolData(solverPoolAddress);
        assertEq(exitTs, block.timestamp + exitDelay, "exit timestamp not as expected");
        assertEq(hasExited, false, "hasExited not as expected");

        uint256 beforeExitTs = exitTs;
        vm.warp(exitTs);
        vm.prank(solver);
        solverPool.exit();
        (, exitTs, hasExited) = factory.subPoolData(solverPoolAddress);
        assertEq(exitTs, beforeExitTs, "exit timestamp not as expected");
        assertEq(hasExited, true, "hasExited not as expected");
    }

    function testBill() external {
        // only relied users can fine
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        factory.bill(solverPoolAddress, 1 ether, 10000 ether, 0.1 ether, "billing reason");

        vm.deal(solverPoolAddress, 1 ether);
        uint256 wethBalanceBefore = weth.balanceOf(address(this));
        uint256 cowBalanceBefore = cow.balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance;
        uint256 wethFined = 0.1 ether;
        uint256 cowFined = 10 ether;
        uint256 ethFined = 0.01 ether;
        factory.bill(solverPoolAddress, wethFined, cowFined, ethFined, "testing bill");

        assertEq(weth.balanceOf(address(this)) - wethBalanceBefore, wethFined, "weth not fined as expected");
        assertEq(cow.balanceOf(address(this)) - cowBalanceBefore, cowFined, "cow not fined as expected");
        assertEq(address(this).balance - ethBalanceBefore, ethFined, "eth not fined as expected");
        (, uint88 exitTimestamp, bool hasExited) = factory.subPoolData(solverPoolAddress);
        assertEq(exitTimestamp, 0, "pool shouldn't have announced exit yet");
        assertEq(hasExited, false, "pool shouldn't be frozen");

        // bill should work in exit period
        vm.prank(solver);
        solverPool.announceExit();

        ethBalanceBefore = address(this).balance;
        factory.bill(solverPoolAddress, 0, 0, 1, "billing in exit period");
        assertEq(address(this).balance - ethBalanceBefore, 1, "didnt bill as expected");

        // bill shouldn't work after the exit delay has elapsed
        ethBalanceBefore = address(this).balance;
        (, exitTimestamp,) = factory.subPoolData(solverPoolAddress);
        vm.warp(exitTimestamp);
        vm.expectRevert(SubPool.SubPool__CannotBillAfterExitDelay.selector);
        factory.bill(solverPoolAddress, 0, 0, 1, "billing after exit delay");
    }

    function testSetExitDelay() external {
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        factory.setExitDelay(1);

        factory.setExitDelay(1);
        (uint32 exitDelay,) = factory.cfg();
        assertEq(exitDelay, 1, "exit delay not set as expected");
    }

    function testSetMinCowAmt() external {
        vm.prank(notOwner);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        factory.setMinCowAmt(1);

        factory.setMinCowAmt(1);
        (, uint224 minCowAmt) = factory.cfg();
        assertEq(minCowAmt, 1, "min cow amt not set as expected");
    }

    function testExitTimestamp() external {
        assertEq(factory.exitTimestamp(solverPoolAddress), 0, "pool hasnt exited yet");

        // quit the pool
        vm.prank(solverPoolAddress);
        factory.announceExit();
        uint256 exitTs = block.timestamp + exitDelay;
        assertEq(factory.exitTimestamp(solverPoolAddress), exitTs, "exit timestamp not as expected");

        // exit the pool, verify the exit timestamp doesnt change even on exit
        vm.warp(exitTs);
        vm.prank(solverPoolAddress);
        factory.exitPool();
        assertEq(factory.exitTimestamp(solverPoolAddress), exitTs, "exit timestamp not as expected");
    }

    function testAnnounceExit() external {
        // addresses not spawned by the factory's create method shouldn't be able to
        // call quit pool
        vm.prank(notOwner);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.announceExit();

        assertEq(factory.exitTimestamp(solverPoolAddress), 0, "no exit timestamp before announce exit");
        vm.prank(solverPoolAddress);
        factory.announceExit();
        assertEq(
            factory.exitTimestamp(solverPoolAddress),
            block.timestamp + exitDelay,
            "exit timestamp not set by announce exit"
        );

        // pool cannot quit twice
        vm.prank(solverPoolAddress);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__PoolAlreadyAnnouncedExit.selector);
        factory.announceExit();
    }

    function testExitPool() external {
        // addresses not spawned by the factory's create method shouldn't be able to
        // call exit pool
        vm.prank(notOwner);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.exitPool();

        // try to exit without quit
        vm.prank(solverPoolAddress);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__PoolHasNotAnnouncedExitYet.selector);
        factory.exitPool();

        // exit time not elapsed
        vm.startPrank(solverPoolAddress);
        factory.announceExit();
        vm.expectRevert(SubPoolFactory.SubPoolFactory__ExitDelayNotElapsed.selector);
        factory.exitPool();
        vm.stopPrank();

        uint256 exitTs = factory.exitTimestamp(solverPoolAddress);
        vm.warp(exitTs);
        vm.prank(solverPoolAddress);
        factory.exitPool();
        (,, bool hasExited) = factory.subPoolData(solverPoolAddress);
        assertEq(hasExited, true, "pool not marked exited");

        // try to exit again, should fail
        vm.prank(solverPoolAddress);
        vm.expectRevert(SubPoolFactory.SubPoolFactory__PoolAlreadyExited.selector);
        factory.exitPool();
    }

    function testUpdateBackendUri() external {
        assertEq(factory.backendUri(solverPoolAddress), backendUri, "backend uri not as expected");
        string memory newBackendUri = "https://new-backend.solver.com";
        vm.prank(solver);
        solverPool.updateBackendUri(newBackendUri);
        assertEq(factory.backendUri(solverPoolAddress), newBackendUri);
    }

    function testCanSolve() external {
        assertEq(factory.canSolve(solver), true, "pool should be a solver");

        vm.deal(solverPoolAddress, 1 ether);
        factory.bill(solverPoolAddress, 0, 0, 1, "pool shouldnt be a solver if there are dues");
        assertEq(factory.canSolve(solver), false, "pool shouldnt be a solver");

        // pay the dues and that should restore solvability
        solverPool.heal{value: 1}();
        assertEq(factory.canSolve(solver), true, "pool should be a solver again after the pool is healed");

        // announce exit
        vm.prank(solverPoolAddress);
        factory.announceExit();
        assertEq(factory.canSolve(solver), false, "announced exited pools shouldnt be a solver");

        // exit pool
        uint256 exitTs = factory.exitTimestamp(solverPoolAddress);
        vm.warp(exitTs);
        vm.prank(solverPoolAddress);
        factory.exitPool();

        // uninited pools should revert
        vm.expectRevert(SubPoolFactory.SubPoolFactory__UnknownPool.selector);
        factory.canSolve(makeAddr("someUninitedpool"));
    }

    receive() external payable {}
}
