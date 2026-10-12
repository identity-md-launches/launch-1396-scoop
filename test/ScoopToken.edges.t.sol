// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm, stdError} from "forge-std/Test.sol";
import {ScoopToken} from "../src/ScoopToken.sol";

/// @notice A spender contract, as a pool, router or distributor would be: pulls with transferFrom
/// and pays with transfer. Nothing about it is exempted by the token.
contract SpenderProbe {
    function pull(ScoopToken token, address from, uint256 amount) external returns (bool) {
        return token.transferFrom(from, address(this), amount);
    }

    function pay(ScoopToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice Edge inputs and failure paths of `ScoopToken` beyond the accepted unit suite: zero, one
/// wei, the whole supply, the maximum, the same call twice, callers the code did not assume, and
/// the order in which the two checks of `transferFrom` fire. Property tests fuzz the arithmetic
/// at its edges with `bound`, never `vm.assume`, so every run exercises the token.
contract ScoopTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 constant MAX = type(uint256).max;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address spender = makeAddr("spender");

    ScoopToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new ScoopToken();
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Supply: exactly one mint, nothing before, nothing after
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_supplyIsExactlyOneBillionTimesTenToTheEighteen() public view {
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
        assertEq(token.totalSupply(), 1e9 * 1e18);
        assertEq(token.totalSupply() / (10 ** token.decimals()), 1_000_000_000);
        assertEq(token.totalSupply() % (10 ** token.decimals()), 0);
    }

    /// @dev Two deployments are two independent supplies: nothing about the mint is shared or
    /// repeated inside one contract.
    function test_eachDeploymentMintsItsOwnSupplyOnce() public {
        vm.prank(alice);
        ScoopToken second = new ScoopToken();
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Nobody else holds anything at construction: the deployer's balance is the whole supply.
    function testFuzz_onlyTheDeployerHoldsAnythingAtConstruction(address anyone) public view {
        if (anyone == deployer) {
            assertEq(token.balanceOf(anyone), SUPPLY);
        } else {
            assertEq(token.balanceOf(anyone), 0);
        }
        assertEq(token.allowance(deployer, anyone), 0);
        assertEq(token.allowance(anyone, deployer), 0);
    }

    /// @dev The constructor emits exactly one Transfer and no Approval: the log count is one.
    function test_constructorEmitsExactlyOneEvent() public {
        vm.recordLogs();
        vm.prank(deployer);
        ScoopToken fresh = new ScoopToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "constructor emitted more than one event");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(deployer))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // transfer: edges
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_transferOneWei() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
    }

    /// @dev Zero to the zero address is still refused: the recipient check comes first.
    function test_transferZeroToZeroAddressReverts() public {
        vm.expectRevert(ScoopToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.transfer(address(0), 0);
    }

    /// @dev An empty account cannot send to the zero address either, and the error is ZeroAddress,
    /// not InsufficientBalance: the recipient is checked before the balance.
    function test_transferToZeroAddressFromEmptyAccountRevertsWithZeroAddress() public {
        vm.expectRevert(ScoopToken.ZeroAddress.selector);
        vm.prank(bob);
        token.transfer(address(0), 1);
    }

    function test_transferMaxUintReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, deployer, SUPPLY, MAX));
        vm.prank(deployer);
        token.transfer(alice, MAX);
    }

    /// @dev The same whole-balance transfer twice: the second must fail by exactly the amount.
    function test_transferWholeBalanceTwiceFailsTheSecondTime() public {
        vm.startPrank(deployer);
        token.transfer(alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, deployer, 0, SUPPLY));
        token.transfer(alice, SUPPLY);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    /// @dev Zero-amount transfers from an empty account succeed and emit, as ERC-20 requires.
    function test_transferZeroFromEmptyAccountEmits() public {
        vm.expectEmit();
        emit Transfer(bob, alice, 0);
        vm.prank(bob);
        assertTrue(token.transfer(alice, 0));
    }

    /// @dev A contract can receive and hold tokens; no hook or callback is attempted.
    function test_transferToAContractWithoutReceiverHookSucceeds() public {
        SpenderProbe probe = new SpenderProbe();
        vm.prank(deployer);
        assertTrue(token.transfer(address(probe), 5e18));
        assertEq(token.balanceOf(address(probe)), 5e18);
        assertTrue(probe.pay(token, alice, 5e18));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.balanceOf(address(probe)), 0);
    }

    /// @dev Tokens sent to the token's own address are accepted and stuck: there is no recovery
    /// function, by design. Supply is still conserved.
    function test_transferToTokenItselfIsAcceptedAndConserved() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 1e18));
        assertEq(token.balanceOf(address(token)), 1e18);
        assertEq(token.balanceOf(deployer) + token.balanceOf(address(token)), SUPPLY);
        (bool ok,) = address(token).call(abi.encodeWithSignature("recover(address,uint256)", deployer, 1e18));
        assertFalse(ok);
        (ok,) = address(token)
            .call(abi.encodeWithSignature("rescueTokens(address,address,uint256)", token, deployer, 1e18));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 1e18);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // transferFrom: edges and the order of its two checks
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The owner is not implicitly its own spender: transferFrom on one's own tokens needs an
    /// allowance like anyone else's.
    function test_ownerCannotTransferFromItselfWithoutSelfAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(deployer, alice, 1);
    }

    function test_ownerCanTransferFromItselfWithSelfAllowance() public {
        vm.startPrank(deployer);
        token.approve(deployer, 3);
        assertTrue(token.transferFrom(deployer, alice, 2));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 2);
        assertEq(token.allowance(deployer, deployer), 1);
    }

    /// @dev Allowance is checked before balance: with neither sufficient, the allowance error wins.
    function test_transferFromChecksAllowanceBeforeBalance() public {
        vm.prank(alice);
        token.approve(spender, 5);
        // alice holds 0, allowance 5, asks 10: InsufficientAllowance, not InsufficientBalance.
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, 5, 10));
        vm.prank(spender);
        token.transferFrom(alice, bob, 10);
    }

    /// @dev Allowance sufficient, balance not: the allowance decrement is rolled back with the revert.
    function test_transferFromAboveBalanceLeavesAllowanceIntact() public {
        vm.prank(alice);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, alice, 0, 7));
        vm.prank(spender);
        token.transferFrom(alice, bob, 7);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Unlimited allowance does not bypass the balance check.
    function test_transferFromInfiniteAllowanceStillNeedsBalance() public {
        vm.prank(alice);
        token.approve(spender, MAX);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, alice, 0, 1));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, spender), MAX);
    }

    /// @dev Exactly the allowance, then one more wei: the first spends it to zero, the second fails.
    function test_transferFromExactAllowanceThenOneMoreFails() public {
        vm.prank(deployer);
        token.approve(spender, 100);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(deployer, alice, 100));
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(deployer, alice, 1);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 100);
    }

    /// @dev An allowance one below the sentinel is finite and is decremented like any other.
    function test_allowanceOneBelowMaxIsFinite() public {
        vm.prank(deployer);
        token.approve(spender, MAX - 1);
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.allowance(deployer, spender), MAX - 2);
    }

    /// @dev A zero-amount transferFrom with zero allowance succeeds and spends nothing; it emits an
    /// Approval of zero because the decrement path still runs.
    function test_transferFromZeroWithZeroAllowanceSucceeds() public {
        vm.expectEmit();
        emit Approval(deployer, spender, 0);
        vm.expectEmit();
        emit Transfer(deployer, alice, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 0));
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev A contract spender (a pool, a router) pulls exactly what it was allowed and no more.
    function test_contractSpenderPullsExactlyAndNoMore() public {
        SpenderProbe probe = new SpenderProbe();
        vm.prank(deployer);
        token.approve(address(probe), 10e18);
        assertTrue(probe.pull(token, deployer, 10e18));
        assertEq(token.balanceOf(address(probe)), 10e18);
        assertEq(token.allowance(deployer, address(probe)), 0);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, address(probe), 0, 1));
        probe.pull(token, deployer, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // The zero address can never be a source of tokens
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Even with the zero address as msg.sender (which only a cheatcode can arrange), nothing
    /// can be sent from it: it holds nothing.
    function test_zeroAddressCannotSendAnything() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, address(0), 0, 1));
        vm.prank(address(0));
        token.transfer(alice, 1);
    }

    /// @dev Approving from the zero address grants an allowance, but there is no balance behind it,
    /// so no spender can mint by pulling from it.
    function test_allowanceFromZeroAddressCannotMint() public {
        vm.prank(address(0));
        token.approve(spender, MAX);
        assertEq(token.allowance(address(0), spender), MAX);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, address(0), 0, 1));
        vm.prank(spender);
        token.transferFrom(address(0), alice, 1);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // approve / increaseAllowance / decreaseAllowance: edges
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_approveZeroClearsAllowanceAndEmits() public {
        vm.startPrank(deployer);
        token.approve(spender, 9);
        vm.expectEmit();
        emit Approval(deployer, spender, 0);
        token.approve(spender, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
    }

    /// @dev Anyone, even with no balance, may approve any amount; allowance is independent of balance.
    function test_approveWithoutBalanceSucceeds() public {
        vm.prank(bob);
        assertTrue(token.approve(spender, MAX));
        assertEq(token.allowance(bob, spender), MAX);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_approveSelfAsSpender() public {
        vm.prank(alice);
        assertTrue(token.approve(alice, 5));
        assertEq(token.allowance(alice, alice), 5);
    }

    function test_approveIsIdempotent() public {
        vm.startPrank(deployer);
        token.approve(spender, 77);
        token.approve(spender, 77);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 77);
    }

    function test_increaseAllowanceRevertsForZeroSpender() public {
        vm.expectRevert(ScoopToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.increaseAllowance(address(0), 1);
    }

    /// @dev decreaseAllowance(zero spender, 0) does not underflow but still hits the zero check.
    function test_decreaseAllowanceRevertsForZeroSpender() public {
        vm.expectRevert(ScoopToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.decreaseAllowance(address(0), 0);
    }

    function test_increaseAllowanceToExactlyMaxSucceeds() public {
        vm.startPrank(deployer);
        token.approve(spender, 1);
        assertTrue(token.increaseAllowance(spender, MAX - 1));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), MAX);
    }

    function test_increaseAllowanceOverflowIsCheckedPanic() public {
        vm.startPrank(deployer);
        token.approve(spender, MAX);
        vm.expectRevert(stdError.arithmeticError);
        token.increaseAllowance(spender, 1);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), MAX);
    }

    function test_increaseAllowanceByZeroAtMaxSucceeds() public {
        vm.startPrank(deployer);
        token.approve(spender, MAX);
        assertTrue(token.increaseAllowance(spender, 0));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), MAX);
    }

    function test_decreaseAllowanceToExactlyZero() public {
        vm.startPrank(deployer);
        token.approve(spender, 4);
        assertTrue(token.decreaseAllowance(spender, 4));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_decreaseAllowanceByOneFromZeroReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(deployer);
        token.decreaseAllowance(spender, 1);
    }

    /// @dev Decreasing an unlimited allowance makes it finite: the sentinel is just a number.
    function test_decreaseAllowanceFromMaxMakesItFinite() public {
        vm.startPrank(deployer);
        token.approve(spender, MAX);
        token.decreaseAllowance(spender, 1);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), MAX - 1);
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
        assertEq(token.allowance(deployer, spender), MAX - 2);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Launch flow mirror: factory -> distributor -> claimants, pool pull, remainder
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The three launch flows in the proportions the README records (10% swarm, 80% pool,
    /// 10% remainder) all arrive whole, and the swarm's share is claimable whole by many claimants
    /// down to the last wei.
    function test_launchFlowsArriveWhole() public {
        address distributor = makeAddr("distributor");
        SpenderProbe pool = new SpenderProbe();
        address remainderTo = makeAddr("remainderTo");

        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        uint256 poolShare = (SUPPLY * 8_000) / 10_000;
        uint256 remainder = SUPPLY - swarm - poolShare;

        vm.startPrank(deployer);
        assertTrue(token.transfer(distributor, swarm));
        token.approve(address(pool), poolShare);
        vm.stopPrank();
        assertTrue(pool.pull(token, deployer, poolShare));
        vm.prank(deployer);
        assertTrue(token.transfer(remainderTo, remainder));

        assertEq(token.balanceOf(deployer), 0, "the factory kept something back");
        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(address(pool)), poolShare);
        assertEq(token.balanceOf(remainderTo), remainder);

        // 7 claimants share the swarm's 10% with a remainder that does not divide evenly.
        uint256 claimants = 7;
        uint256 each = swarm / claimants;
        uint256 paid;
        for (uint256 i = 0; i < claimants; i++) {
            address claimant = makeAddr(string.concat("claimant", vm.toString(i)));
            uint256 amount = i == claimants - 1 ? swarm - paid : each;
            vm.prank(distributor);
            assertTrue(token.transfer(claimant, amount));
            assertEq(token.balanceOf(claimant), amount, "a claim arrived short");
            paid += amount;
        }
        assertEq(paid, swarm);
        assertEq(token.balanceOf(distributor), 0, "the distributor kept something back");
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Property tests at the edges
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Any two-hop route conserves supply and lands exactly: deployer -> a -> b.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_twoHopTransferLandsExactly(address a, address b, uint256 first, uint256 second) public {
        a = _nonZero(a);
        b = _nonZero(b);
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, first);
        vm.prank(deployer);
        token.transfer(a, first);
        uint256 aBefore = token.balanceOf(a);
        uint256 bBefore = token.balanceOf(b);
        vm.prank(a);
        assertTrue(token.transfer(b, second));
        if (a == b) {
            assertEq(token.balanceOf(a), aBefore);
        } else {
            assertEq(token.balanceOf(a), aBefore - second);
            assertEq(token.balanceOf(b), bBefore + second);
        }
        uint256 sum = token.balanceOf(deployer);
        if (a != deployer) sum += token.balanceOf(a);
        if (b != deployer && b != a) sum += token.balanceOf(b);
        assertEq(sum, SUPPLY);
    }

    /// @dev One wei above the balance always reverts with the exact figures, for any balance.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_oneWeiAboveBalanceReverts(uint256 held) public {
        held = bound(held, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, alice, held, held + 1));
        vm.prank(alice);
        token.transfer(bob, held + 1);
        assertEq(token.balanceOf(alice), held);
    }

    /// @dev A self-transfer of any amount up to the balance changes nothing (idempotence).
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_selfTransferIsIdentity(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, amount));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Transfers to the zero address revert for every amount, zero included.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_zeroRecipientAlwaysReverts(uint256 amount) public {
        vm.expectRevert(ScoopToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.transfer(address(0), amount);
    }

    /// @dev approve overwrites: the last value wins regardless of what came before.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveLastWriteWins(address who, uint256 a, uint256 b) public {
        who = _nonZero(who);
        vm.startPrank(deployer);
        token.approve(who, a);
        token.approve(who, b);
        vm.stopPrank();
        assertEq(token.allowance(deployer, who), b);
    }

    /// @dev increase then decrease by the same amount is a round-trip back to the start.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_increaseThenDecreaseRoundTrips(uint256 start, uint256 delta) public {
        start = bound(start, 0, MAX);
        delta = bound(delta, 0, MAX - start);
        vm.startPrank(deployer);
        token.approve(spender, start);
        token.increaseAllowance(spender, delta);
        assertEq(token.allowance(deployer, spender), start + delta);
        token.decreaseAllowance(spender, delta);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), start);
    }

    /// @dev Any increase that would pass the maximum is refused with a checked-arithmetic panic.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_increaseAllowancePastMaxReverts(uint256 start, uint256 delta) public {
        start = bound(start, 1, MAX);
        delta = bound(delta, MAX - start + 1, MAX);
        vm.startPrank(deployer);
        token.approve(spender, start);
        vm.expectRevert(stdError.arithmeticError);
        token.increaseAllowance(spender, delta);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), start);
    }

    /// @dev Any decrease below the current allowance is refused with the exact figures.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_decreaseAllowanceBelowZeroReverts(uint256 start, uint256 delta) public {
        start = bound(start, 0, MAX - 1);
        delta = bound(delta, start + 1, MAX);
        vm.startPrank(deployer);
        token.approve(spender, start);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, start, delta));
        token.decreaseAllowance(spender, delta);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), start);
    }

    /// @dev Under an unlimited allowance, any number of pulls up to the balance leaves it unlimited
    /// and moves exactly the sum.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_infiniteAllowanceSurvivesRepeatedPulls(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        c = bound(c, 0, SUPPLY - a - b);
        vm.prank(deployer);
        token.approve(spender, MAX);
        vm.startPrank(spender);
        token.transferFrom(deployer, alice, a);
        token.transferFrom(deployer, alice, b);
        token.transferFrom(deployer, alice, c);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), MAX);
        assertEq(token.balanceOf(alice), a + b + c);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b - c);
    }

    /// @dev Spending a finite allowance in several pulls is the same as one pull of the sum; the
    /// pull that crosses the allowance fails with the exact remaining figure.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_finiteAllowanceIsSpentExactlyAcrossPulls(uint256 allowed, uint256 a, uint256 b) public {
        allowed = bound(allowed, 0, SUPPLY);
        a = bound(a, 0, allowed);
        b = bound(b, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.startPrank(spender);
        token.transferFrom(deployer, alice, a);
        uint256 remaining = allowed - a;
        if (b > remaining) {
            vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, remaining, b));
            token.transferFrom(deployer, alice, b);
            assertEq(token.balanceOf(alice), a);
            assertEq(token.allowance(deployer, spender), remaining);
        } else {
            token.transferFrom(deployer, alice, b);
            assertEq(token.balanceOf(alice), a + b);
            assertEq(token.allowance(deployer, spender), remaining - b);
        }
        vm.stopPrank();
    }

    /// @dev Whoever the caller, a transferFrom on an owner that never approved them fails and moves
    /// nothing. The deployer gets no special treatment.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nobodyPullsWithoutApproval(address caller, uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, caller, 0, amount));
        vm.prank(caller);
        token.transferFrom(alice, caller, amount);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    /// @dev The deployer, the factory's stand-in, has exactly the same powers as any holder: it
    /// cannot pull from a holder, and after giving everything away it cannot send a wei.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_deployerHasNoResidualPower(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, deployer, 0, amount));
        vm.prank(deployer);
        token.transfer(bob, amount);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, deployer, 0, amount));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, amount);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function _nonZero(address a) internal pure returns (address) {
        return a == address(0) ? address(1) : a;
    }
}
