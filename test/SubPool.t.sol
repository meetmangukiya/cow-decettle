pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SubPool, ISubPoolFactory, Auth} from "src/SubPool.sol";
import {MockToken} from "./MockToken.sol";

contract MockFactory {
    uint256 public immutable amtDue;
    uint256 public immutable cowAmtDue;

    constructor(uint256 amt, uint256 cowAmt) {
        amtDue = amt;
        cowAmtDue = cowAmt;
    }

    function dues(address) external view returns (uint256 amt, uint256 cowAmt) {
        return (amtDue, cowAmtDue);
    }

    function exitPool() external {}
    function quitPool() external {}
    function exitTimestamp(address) external view returns (uint256) {}
}

contract SubPoolTest is Test {
    SubPool pool;
    MockToken collateralToken;
    MockToken COW;
    MockFactory factory;
    uint256 amtDue = 1 ether;
    uint256 cowAmtDue = 10 ether;

    function setUp() external {
        collateralToken = new MockToken("Collateral", "CLT");
        COW = new MockToken("COW", "COW");
        factory = new MockFactory(amtDue, cowAmtDue);
        vm.prank(address(factory));
        pool = new SubPool(address(this), address(COW));
        pool.initializeCollateralToken(address(collateralToken));
    }

    function testDues() external {
        vm.expectCall(address(factory), abi.encodeCall(ISubPoolFactory.dues, (address(pool))));
        (uint256 amt, uint256 cowAmt) = pool.dues();
        assertEq(amt, amtDue, "token amt due is incorrect");
        assertEq(cowAmt, cowAmtDue, "cow token amt due is incorrect");
    }

    function testHeal() external {
        // anyone can heal
        address user = makeAddr("user");
        assertEq(pool.wards(user), false, "user is a ward");

        deal(address(collateralToken), user, amtDue);
        deal(address(COW), user, cowAmtDue);

        vm.startPrank(user);
        collateralToken.approve(address(pool), amtDue);
        COW.approve(address(pool), cowAmtDue);
        pool.heal();
        vm.stopPrank();

        assertEq(collateralToken.balanceOf(address(pool)), amtDue, "heal did not transfer the tokens");
        assertEq(COW.balanceOf(address(pool)), cowAmtDue, "heal did not transfer the tokens");
    }

    function testQuit() external {
        // pool should notify the factory
        vm.expectCall(address(factory), abi.encodeCall(ISubPoolFactory.quitPool, ()));
        pool.quit();

        vm.expectRevert(Auth.Auth__OnlyWards.selector);
        vm.prank(makeAddr("user"));
        pool.quit();
    }

    function testExit() external {
        uint256 tokenAmt = 10 ether;
        uint256 cowAmt = 100 ether;

        deal(address(collateralToken), address(pool), tokenAmt);
        deal(address(COW), address(pool), cowAmt);

        vm.mockCall(
            address(factory),
            abi.encodeCall(ISubPoolFactory.exitTimestamp, (address(pool))),
            abi.encode(block.timestamp)
        );
        address user = makeAddr("user");
        address owner = pool.owner();

        // any user can call exit, the assets will go to the owner
        uint256 collBalanceBefore = collateralToken.balanceOf(owner);
        uint256 cowBalanceBefore = COW.balanceOf(owner);

        vm.prank(user);
        pool.exit();

        uint256 collBalanceAfter = collateralToken.balanceOf(owner);
        uint256 cowBalanceAfter = COW.balanceOf(owner);

        assertEq(collBalanceAfter - collBalanceBefore, tokenAmt, "exit didnt transfer the pool assets to the owner");
        assertEq(cowBalanceAfter - cowBalanceBefore, cowAmt, "exit didnt transfer the pool assets to the owner");
    }

    function testSlip() external {
        deal(address(collateralToken), address(pool), 1 ether);
        deal(address(COW), address(pool), 10 ether);

        address receiver = makeAddr("receiver");
        vm.prank(address(factory));
        pool.slip(0.1 ether, 1 ether, receiver);

        assertEq(collateralToken.balanceOf(receiver), 0.1 ether, "slip didnt transfer tokens as expected");
        assertEq(COW.balanceOf(receiver), 1 ether, "slip didnt transfer tokens as expected");

        vm.expectRevert(SubPool.SubPool__OnlyFactory.selector);
        pool.slip(0.1 ether, 1 ether, receiver);
    }
}
