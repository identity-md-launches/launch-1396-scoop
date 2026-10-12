// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ScoopToken} from "../src/ScoopToken.sol";

/// @notice Drives `ScoopToken` with bounded inputs from several actors, in whatever order the
/// invariant runner picks, and keeps a ghost ledger of what every address should hold and what
/// every allowance should be. Every handler also exercises the matching failure path: a call that
/// must revert is made through try/catch and the exact error is asserted, so a revert that goes
/// missing, or a revert that leaves state half-written, fails the run.
/// @dev The handler never reverts on its own. The invariant runs with `fail-on-revert = true`, so
/// any assertion failure inside a handler, or any unexpected revert of the token, fails the test.
contract ScoopHandler is Test {
    ScoopToken public immutable token;
    uint256 public immutable supply;

    /// @dev Actors the fuzzer picks from. Index 0 is the deployer, which starts with the supply.
    address[] internal actors;

    /// @dev Every address that has ever been a transfer recipient or sender, deduplicated, so the
    /// conservation invariant can sum balances over the whole holder set, including arbitrary
    /// fuzzed recipients that are not actors.
    address[] internal holders;
    mapping(address => bool) internal isHolder;

    // Ghost ledger: expected balance = initial + received - sent.
    mapping(address => uint256) public ghostInitial;
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostReceived;
    // Ghost allowance mirror for every (owner, spender) pair the handler has touched.
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    // Call counters, for reading the run's coverage from the summary.
    uint256 public callsTransfer;
    uint256 public callsTransferToAnyone;
    uint256 public callsTransferAboveBalance;
    uint256 public callsTransferToZero;
    uint256 public callsSelfTransfer;
    uint256 public callsApprove;
    uint256 public callsApproveZeroSpender;
    uint256 public callsIncreaseAllowance;
    uint256 public callsIncreaseAllowanceOverflow;
    uint256 public callsDecreaseAllowance;
    uint256 public callsDecreaseAllowanceBelowZero;
    uint256 public callsTransferFrom;
    uint256 public callsTransferFromAboveAllowance;
    uint256 public callsTransferFromAboveBalance;
    uint256 public callsAdminProbe;

    constructor(ScoopToken token_, address deployer, uint256 actorCount_) {
        token = token_;
        supply = token_.totalSupply();
        _track(deployer);
        actors.push(deployer);
        ghostInitial[deployer] = supply;
        for (uint256 i = 1; i < actorCount_; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            _track(a);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Views for the invariants
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function expectedBalance(address a) public view returns (uint256) {
        return ghostInitial[a] + ghostReceived[a] - ghostSent[a];
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // transfer
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Happy path between two actors, any amount up to the sender's whole balance.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transfer(from, to, amount);
        callsTransfer++;
    }

    /// @dev Transfer to an arbitrary fuzzed address, which may be anyone (a contract, a precompile,
    /// the token itself) or the zero address. The zero address must be refused; anyone else must
    /// receive exactly the amount and become part of the tracked holder set.
    function transferToAnyone(uint256 fromSeed, address to, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        if (to == address(0)) {
            uint256 fromBefore = token.balanceOf(from);
            vm.prank(from);
            try token.transfer(to, amount) {
                fail("transfer to the zero address did not revert");
            } catch (bytes memory reason) {
                assertEq(
                    reason, abi.encodeWithSelector(ScoopToken.ZeroAddress.selector), "wrong error for zero recipient"
                );
            }
            assertEq(token.balanceOf(from), fromBefore, "a refused transfer changed the sender's balance");
            callsTransferToZero++;
            return;
        }
        _transfer(from, to, amount);
        callsTransferToAnyone++;
    }

    /// @dev Sending more than held must revert with the exact shortfall and leave both sides as they were.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        vm.prank(from);
        try token.transfer(to, amount) {
            fail("transfer above balance did not revert");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, from, held, amount),
                "wrong error for insufficient balance"
            );
        }
        assertEq(token.balanceOf(from), held, "a refused transfer changed the sender's balance");
        assertEq(token.balanceOf(to), toBefore, "a refused transfer changed the recipient's balance");
        callsTransferAboveBalance++;
    }

    /// @dev A self-transfer of any amount up to the balance is a no-op on the balance.
    function selfTransfer(uint256 actorSeed, uint256 amount) external {
        address who = _actor(actorSeed);
        uint256 held = token.balanceOf(who);
        amount = bound(amount, 0, held);
        vm.prank(who);
        assertTrue(token.transfer(who, amount), "self-transfer returned false");
        assertEq(token.balanceOf(who), held, "self-transfer changed the balance");
        ghostSent[who] += amount;
        ghostReceived[who] += amount;
        callsSelfTransfer++;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // approve / increaseAllowance / decreaseAllowance
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Any amount, including zero and the unlimited sentinel; overwrites whatever was there.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        callsApprove++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            fail("approve of the zero spender did not revert");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(ScoopToken.ZeroAddress.selector), "wrong error for zero spender");
        }
        assertEq(token.allowance(owner, address(0)), 0, "the zero spender gained an allowance");
        callsApproveZeroSpender++;
    }

    function increaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 added) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        added = bound(added, 0, type(uint256).max - current);
        vm.prank(owner);
        assertTrue(token.increaseAllowance(spender, added), "increaseAllowance returned false");
        ghostAllowance[owner][spender] = current + added;
        callsIncreaseAllowance++;
    }

    /// @dev Pushing the allowance past uint256 must revert (checked arithmetic), not wrap to a small value.
    function increaseAllowanceOverflow(uint256 ownerSeed, uint256 spenderSeed, uint256 added) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        if (current == 0) return; // nothing can overflow from zero
        added = bound(added, type(uint256).max - current + 1, type(uint256).max);
        vm.prank(owner);
        try token.increaseAllowance(spender, added) {
            fail("increaseAllowance overflow did not revert");
        } catch (bytes memory reason) {
            // Panic(0x11): arithmetic overflow.
            assertEq(
                reason, abi.encodeWithSelector(bytes4(0x4e487b71), uint256(0x11)), "overflow was not a checked panic"
            );
        }
        assertEq(token.allowance(owner, spender), current, "a refused increase changed the allowance");
        callsIncreaseAllowanceOverflow++;
    }

    function decreaseAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 subtracted) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        subtracted = bound(subtracted, 0, current);
        vm.prank(owner);
        assertTrue(token.decreaseAllowance(spender, subtracted), "decreaseAllowance returned false");
        ghostAllowance[owner][spender] = current - subtracted;
        callsDecreaseAllowance++;
    }

    function decreaseAllowanceBelowZero(uint256 ownerSeed, uint256 spenderSeed, uint256 subtracted) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 current = token.allowance(owner, spender);
        if (current == type(uint256).max) return; // nothing is above the maximum
        subtracted = bound(subtracted, current + 1, type(uint256).max);
        vm.prank(owner);
        try token.decreaseAllowance(spender, subtracted) {
            fail("decreaseAllowance below zero did not revert");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, current, subtracted),
                "wrong error for decrease below zero"
            );
        }
        assertEq(token.allowance(owner, spender), current, "a refused decrease changed the allowance");
        callsDecreaseAllowanceBelowZero++;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // transferFrom
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Spends within both the owner's balance and the spender's allowance. An unlimited
    /// allowance must stay unlimited; a finite one must drop by exactly the amount.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        uint256 cap = allowed == type(uint256).max ? held : (allowed < held ? allowed : held);
        amount = bound(amount, 0, cap);

        uint256 ownerBefore = held;
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "unlimited allowance was decremented");
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance did not drop by the amount");
            ghostAllowance[owner][spender] = allowed - amount;
        }
        _recordMove(owner, to, amount, ownerBefore, toBefore);
        callsTransferFrom++;
    }

    /// @dev Spending above a finite allowance must revert with the exact figures, whatever the balance.
    function transferFromAboveAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) return; // unlimited: nothing is above it
        amount = bound(amount, allowed + 1, type(uint256).max);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            fail("transferFrom above allowance did not revert");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, allowed, amount),
                "wrong error for insufficient allowance"
            );
        }
        assertEq(token.allowance(owner, spender), allowed, "a refused transferFrom changed the allowance");
        assertEq(token.balanceOf(owner), ownerBefore, "a refused transferFrom changed the owner's balance");
        assertEq(token.balanceOf(to), toBefore, "a refused transferFrom changed the recipient's balance");
        callsTransferFromAboveAllowance++;
    }

    /// @dev Allowance covers it but the owner's balance does not: must revert with InsufficientBalance,
    /// and the allowance decrement that happens before the balance check must be rolled back.
    function transferFromAboveBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        if (allowed <= held) return; // cannot be above the balance and within the allowance
        amount = bound(amount, held + 1, allowed);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            fail("transferFrom above balance did not revert");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, owner, held, amount),
                "wrong error for insufficient owner balance"
            );
        }
        assertEq(token.allowance(owner, spender), allowed, "a reverted transferFrom still spent allowance");
        assertEq(token.balanceOf(owner), held, "a refused transferFrom changed the owner's balance");
        assertEq(token.balanceOf(to), toBefore, "a refused transferFrom changed the recipient's balance");
        callsTransferFromAboveBalance++;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Privileged surface that must not exist
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev Any actor, the deployer included, tries one of the admin selectors the launch floor
    /// probes. Every one must fail; the invariants then confirm nothing moved.
    function adminProbe(uint256 actorSeed, uint256 targetSeed, uint256 sigSeed) external {
        address caller = _actor(actorSeed);
        address target = _actor(targetSeed);
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "seize(address)",
            "setMinter(address)"
        ];
        string memory sig = signatures[bound(sigSeed, 0, signatures.length - 1)];
        bytes memory data = abi.encodeWithSignature(sig, target, type(uint128).max);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, string.concat("privileged call succeeded: ", sig));
        callsAdminProbe++;
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _track(address a) internal {
        if (!isHolder[a]) {
            isHolder[a] = true;
            holders.push(a);
        }
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        _recordMove(from, to, amount, fromBefore, toBefore);
    }

    /// @dev Post-conditions of any successful move plus the ghost ledger update.
    function _recordMove(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore) internal {
        _track(to);
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-move changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender did not lose exactly the amount");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient did not gain exactly the amount");
        }
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
    }
}

/// @notice Invariants of a fixed-supply token under random call sequences. The token holds every
/// holder's balance, so what it owes (the sum of balances) must always equal the one supply it
/// minted, nobody may end up with more than they were sent, and allowances must track exactly
/// what owners granted and spenders spent.
contract ScoopTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

    ScoopToken token;
    ScoopHandler handler;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new ScoopToken();
        handler = new ScoopHandler(token, deployer, 6);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = ScoopHandler.transfer.selector;
        selectors[1] = ScoopHandler.transferToAnyone.selector;
        selectors[2] = ScoopHandler.transferAboveBalance.selector;
        selectors[3] = ScoopHandler.selfTransfer.selector;
        selectors[4] = ScoopHandler.approve.selector;
        selectors[5] = ScoopHandler.approveZeroSpender.selector;
        selectors[6] = ScoopHandler.increaseAllowance.selector;
        selectors[7] = ScoopHandler.increaseAllowanceOverflow.selector;
        selectors[8] = ScoopHandler.decreaseAllowance.selector;
        selectors[9] = ScoopHandler.decreaseAllowanceBelowZero.selector;
        selectors[10] = ScoopHandler.transferFrom.selector;
        selectors[11] = ScoopHandler.transferFromAboveAllowance.selector;
        selectors[12] = ScoopHandler.transferFromAboveBalance.selector;
        selectors[13] = ScoopHandler.adminProbe.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The supply is minted once and can never grow or shrink, whatever anyone calls.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "totalSupply changed");
        assertEq(token.INITIAL_SUPPLY(), SUPPLY, "INITIAL_SUPPLY changed");
    }

    /// @dev Conservation: what the token owes across every address that ever held it equals what it
    /// minted. Tokens never appear or vanish in transit.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.holderAt(i));
        }
        assertEq(sum, token.totalSupply(), "sum of balances != totalSupply");
    }

    /// @dev Ledger: every holder's balance is exactly what it started with plus what it was sent
    /// minus what it sent. Nobody withdraws more than was put in their name.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchGhostLedger() public view {
        uint256 n = handler.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address h = handler.holderAt(i);
            assertEq(token.balanceOf(h), handler.expectedBalance(h), "balance drifted from the ledger");
            assertLe(token.balanceOf(h), SUPPLY, "a holder holds more than the supply");
        }
    }

    /// @dev Allowances: for every actor pair, the contract's allowance equals what the owner granted
    /// and the spender has not yet spent. Unlimited stays unlimited; finite decrements exactly.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.actorAt(i);
            for (uint256 j = 0; j < n; j++) {
                address spender = handler.actorAt(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
            assertEq(token.allowance(owner, address(0)), 0, "the zero spender has an allowance");
        }
    }

    /// @dev The zero address can never hold anything, so nothing can be "burned" by transfer and
    /// nothing can be minted from it; the token itself never accrues ether.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev Liveness: after any sequence, every holder can still move its whole balance, and the
    /// deployer-side flows the launch relies on (whole-amount transfers) still arrive whole.
    /// Checked on a snapshot so the probe does not pollute the sequence.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 32
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyHolderCanStillMoveEverything() public {
        uint256 snap = vm.snapshotState();
        address sink = makeAddr("liveness-sink");
        uint256 n = handler.holderCount();
        uint256 moved;
        for (uint256 i = 0; i < n; i++) {
            address h = handler.holderAt(i);
            if (h == sink) continue;
            uint256 held = token.balanceOf(h);
            if (held == 0) continue;
            vm.prank(h);
            assertTrue(token.transfer(sink, held), "a holder could not move its whole balance");
            assertEq(token.balanceOf(h), 0, "a holder kept something after moving everything");
            moved += held;
        }
        assertEq(token.balanceOf(sink), moved, "the whole-balance transfers arrived short");
        assertEq(moved, SUPPLY, "the holders together did not hold the whole supply");
        vm.revertToState(snap);
    }
}
