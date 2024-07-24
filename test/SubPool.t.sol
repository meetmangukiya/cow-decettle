pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SubPool, ISubPoolFactory, Auth} from "src/SubPool.sol";
import {MockToken, ERC20} from "./MockToken.sol";
import {SubPoolFactory} from "src/SubPoolFactory.sol";

contract SubPoolTest is Test {
    SubPool pool;
    MockToken collateralToken;
    MockToken COW;
    MockToken mockToken;
    SubPoolFactory factory;
    uint256 amtDue = 1 ether;
    uint256 cowAmtDue = 10 ether;
    uint256 ethAmtDue = 5 ether;
    uint32 exitDelay = 1 days;
    uint224 minCowAmt = 10000 ether;
    uint256 collateralAmt = 100 ether;
    uint256 ethAmt = 10 ether;
    address solverPoolAddress;

    function setUp() external {
        collateralToken = new MockToken("Collateral", "CLT");
        vm.label(address(collateralToken), "CLT");
        COW = new MockToken("COW", "COW");
        vm.label(address(COW), "COW");
        mockToken = new MockToken("MTK", "MTK");
        vm.label(address(mockToken), "MTK");
        factory = new SubPoolFactory(exitDelay, minCowAmt, address(COW));

        deal(address(COW), address(this), minCowAmt);
        deal(address(collateralToken), address(this), collateralAmt);
        collateralToken.approve(address(factory), collateralAmt);
        COW.approve(address(factory), minCowAmt);

        pool = SubPool(factory.create(address(collateralToken), collateralAmt, minCowAmt, "https://backend.solver.com"));
        solverPoolAddress = address(pool);
        vm.deal(solverPoolAddress, ethAmt);
    }

    function testDues() external {
        vm.deal(solverPoolAddress, ethAmtDue);

        factory.bill(solverPoolAddress, amtDue, cowAmtDue, ethAmtDue, "billed amount should reflect in dues");

        (uint256 amt, uint256 cowAmt, uint256 ethAmt_) = pool.dues();
        assertEq(amt, amtDue, "token amt due is incorrect");
        assertEq(cowAmt, cowAmtDue, "cow token amt due is incorrect");
        assertEq(ethAmt_, ethAmtDue, "eth amt due is incorrect");
    }

    function testHeal() external {
        // create some dues
        factory.bill(solverPoolAddress, amtDue, cowAmtDue, ethAmtDue, "create some dues for the test");

        // anyone can heal
        address user = makeAddr("user");
        assertEq(pool.isOwner(user), false, "user is a owner");

        uint256 collateralBalanceBefore = collateralToken.balanceOf(address(pool));
        uint256 cowBalanceBefore = COW.balanceOf(address(pool));
        uint256 ethBalanceBefore = solverPoolAddress.balance;

        deal(address(collateralToken), user, amtDue);
        deal(address(COW), user, cowAmtDue);
        vm.deal(user, ethAmtDue);

        vm.startPrank(user);
        collateralToken.approve(address(pool), amtDue);
        COW.approve(address(pool), cowAmtDue);
        pool.heal{value: ethAmtDue}();
        vm.stopPrank();

        assertEq(
            collateralToken.balanceOf(address(pool)),
            collateralBalanceBefore + amtDue,
            "heal did not transfer the tokens"
        );
        assertEq(COW.balanceOf(address(pool)), cowBalanceBefore + cowAmtDue, "heal did not transfer the tokens");
        assertEq(solverPoolAddress.balance, ethBalanceBefore + ethAmtDue, "heal did not transfer enough eth");
    }

    function testAnnounceExit() external {
        // pool should notify the factory
        vm.expectCall(address(factory), abi.encodeCall(ISubPoolFactory.announceExit, ()));
        pool.announceExit();

        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        vm.prank(makeAddr("user"));
        pool.announceExit();
    }

    function testExit() external {
        uint256 tokenAmt = 10 ether;
        uint256 cowAmt = 100 ether;
        uint256 ethAmt_ = 1 ether;

        deal(address(collateralToken), address(pool), tokenAmt);
        deal(address(COW), address(pool), cowAmt);
        vm.deal(solverPoolAddress, ethAmt_);

        SubPool(solverPoolAddress).announceExit();
        uint256 exitTs = factory.exitTimestamp(solverPoolAddress);
        vm.warp(exitTs);

        address user = makeAddr("user");

        // any user can call exit, the assets will go to the owner
        uint256 collBalanceBefore = collateralToken.balanceOf(address(this));
        uint256 cowBalanceBefore = COW.balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance;

        vm.prank(user);
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        pool.exit();

        pool.exit();

        uint256 collBalanceAfter = collateralToken.balanceOf(address(this));
        uint256 cowBalanceAfter = COW.balanceOf(address(this));
        uint256 ethBalanceAfter = address(this).balance;

        assertEq(collBalanceAfter - collBalanceBefore, tokenAmt, "exit didnt transfer the pool assets to the owner");
        assertEq(cowBalanceAfter - cowBalanceBefore, cowAmt, "exit didnt transfer the pool assets to the owner");
        assertEq(ethBalanceAfter - ethBalanceBefore, ethAmt_, "exit didnt tranfer the pool assets to the owner");
    }

    function testBill() external {
        deal(address(collateralToken), address(pool), 1 ether);
        deal(address(COW), address(pool), 10 ether);
        vm.deal(address(pool), 0.1 ether);

        address receiver = makeAddr("receiver");
        vm.prank(address(factory));
        pool.bill(0.1 ether, 1 ether, 0.01 ether, receiver);

        assertEq(collateralToken.balanceOf(receiver), 0.1 ether, "bill didnt transfer tokens as expected");
        assertEq(COW.balanceOf(receiver), 1 ether, "bill didnt transfer tokens as expected");
        assertEq(receiver.balance, 0.01 ether, "bill didnt transfer eth as expected");

        vm.expectRevert(SubPool.SubPool__OnlyFactory.selector);
        pool.bill(0.1 ether, 1 ether, 0.01 ether, receiver);
    }

    function testWithdrawTokens() external {
        deal(address(collateralToken), address(pool), 1 ether);
        deal(address(COW), address(pool), 10 ether);
        deal(address(mockToken), address(pool), 1 ether);
        vm.deal(address(pool), 0.1 ether);

        // shouldnt be able to withdraw collateral token or COW
        address[] memory tks = new address[](1);
        tks[0] = address(collateralToken);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);

        tks[0] = address(COW);
        vm.expectRevert(SubPool.SubPool__InvalidWithdraw.selector);
        pool.withdrawTokens(tks);

        // only owner can withdraw
        tks[0] = address(mockToken);
        vm.prank(makeAddr("user"));
        vm.expectRevert(Auth.Auth__OnlyOwners.selector);
        pool.withdrawTokens(tks);

        address anotherOwner = makeAddr("anotherOwner");
        pool.addOwner(anotherOwner);

        // tokens are sent to the calling owner
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(mockToken.balanceOf(anotherOwner), 1 ether, "MTK balance not as expected");

        // after exit it should be able to withdraw any tokens.
        pool.announceExit();
        uint256 exitTs = factory.exitTimestamp(address(pool));
        vm.warp(exitTs);
        tks[0] = address(collateralToken);
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(collateralToken.balanceOf(anotherOwner), 1 ether, "collateral token balance not as expected");
        assertEq(anotherOwner.balance, 0.1 ether, "ether balance not as expected");
        tks[0] = address(COW);
        vm.prank(anotherOwner);
        pool.withdrawTokens(tks);
        assertEq(COW.balanceOf(anotherOwner), 10 ether, "COW balance not as expected");
    }

    receive() external payable {}
}
