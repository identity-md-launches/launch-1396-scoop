// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ScoopToken} from "../src/ScoopToken.sol";
import {DeployScoop} from "../script/DeployScoop.s.sol";

/// @notice Stands in for the launch factory: deploys the token through CREATE2 so that `msg.sender`
/// in the constructor is a contract, exactly as it is at launch.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(ScoopToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract ScoopTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 1e18;

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
    // Metadata and supply
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(token.name(), "Scoop");
        assertEq(token.symbol(), "SCOOP");
        assertEq(token.decimals(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** token.decimals());
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit();
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new ScoopToken();
    }

    /// @dev Deployed from a contract through CREATE2, the way the launch factory deploys it, the
    /// supply lands on that contract and the contract can pay it out whole.
    function test_deployedByAContractMintsToThatContract() public {
        FactoryProbe factory = new FactoryProbe();
        ScoopToken launched = ScoopToken(factory.deploy(type(ScoopToken).creationCode, bytes32(uint256(7))));
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);

        uint256 swarm = SUPPLY / 10;
        assertTrue(factory.move(launched, alice, swarm));
        assertEq(launched.balanceOf(alice), swarm);
        assertEq(launched.balanceOf(address(factory)), SUPPLY - swarm);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_creationCodeHasNoConstructorArguments() public {
        // The launch appends the manifest's constructor arguments to the creation code. There are
        // none, so the bare creation code must deploy as is.
        FactoryProbe factory = new FactoryProbe();
        address at = factory.deploy(type(ScoopToken).creationCode, bytes32(0));
        assertEq(ScoopToken(at).balanceOf(address(factory)), SUPPLY);
    }

    function test_deployScriptMintsToTheBroadcaster() public {
        DeployScoop script = new DeployScoop();
        // The script contract itself is `msg.sender` of `new ScoopToken()` inside `deploy()`.
        ScoopToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
        assertEq(deployed.name(), "Scoop");
        assertEq(deployed.symbol(), "SCOOP");
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // transfer
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_transferMovesExactAmountAndEmits() public {
        vm.expectEmit();
        emit Transfer(deployer, alice, 1_000e18);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(deployer, 5e18);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        vm.prank(alice);
        token.transfer(bob, 10e18 + 1);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, bob, 0, 1));
        vm.prank(bob);
        token.transfer(alice, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(ScoopToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // approve / transferFrom
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit();
        emit Approval(deployer, spender, 500e18);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 500e18));
        assertEq(token.allowance(deployer, spender), 500e18);
    }

    function test_approveOverwritesPriorAllowance() public {
        vm.startPrank(deployer);
        token.approve(spender, 500e18);
        token.approve(spender, 5e18);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 5e18);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(ScoopToken.ZeroAddress.selector);
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 500e18);

        vm.expectEmit();
        emit Approval(deployer, spender, 200e18);
        vm.expectEmit();
        emit Transfer(deployer, alice, 300e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 300e18));

        assertEq(token.balanceOf(alice), 300e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 300e18);
        assertEq(token.allowance(deployer, spender), 200e18);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1e18);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, 10e18, 10e18 + 1));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 10e18 + 1);
    }

    function test_transferFromRevertsWhenOwnerBalanceTooLow() public {
        vm.prank(alice);
        token.approve(spender, 100e18);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, alice, 0, 1e18));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1e18);
    }

    function test_transferFromRevertsToZeroAddress() public {
        vm.prank(deployer);
        token.approve(spender, 1e18);
        vm.expectRevert(ScoopToken.ZeroAddress.selector);
        vm.prank(spender);
        token.transferFrom(deployer, address(0), 1e18);
    }

    function test_increaseAndDecreaseAllowance() public {
        vm.startPrank(deployer);
        assertTrue(token.increaseAllowance(spender, 7e18));
        assertEq(token.allowance(deployer, spender), 7e18);
        assertTrue(token.increaseAllowance(spender, 3e18));
        assertEq(token.allowance(deployer, spender), 10e18);
        assertTrue(token.decreaseAllowance(spender, 4e18));
        assertEq(token.allowance(deployer, spender), 6e18);
        vm.stopPrank();
    }

    function test_decreaseAllowanceRevertsBelowZero() public {
        vm.prank(deployer);
        token.approve(spender, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, 1e18, 2e18));
        vm.prank(deployer);
        token.decreaseAllowance(spender, 2e18);
    }

    function test_increaseAllowanceRevertsOnOverflow() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.expectRevert(); // checked arithmetic panic
        vm.prank(deployer);
        token.increaseAllowance(spender, 1);
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Fixed supply, no privileged hands
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    /// @dev The same admin surface the launch floor probes. None of it exists, so every call
    /// reverts, and the supply and the attacker's balance never change, whether a stranger or the
    /// deployer tries.
    function test_noAdminCallIncreasesSupplyOrMints() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    /// @dev Nobody but a holder moves or freezes the holder's balance, the deployer included.
    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY / 1_000);
        uint256 held = token.balanceOf(alice);

        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        // The deployer holds no allowance from alice, so it cannot pull from her either.
        vm.prank(deployer);
        (bool moved,) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, alice, deployer, 1));
        assertFalse(moved);
        assertEq(token.balanceOf(alice), held);

        vm.prank(alice);
        assertTrue(token.transfer(bob, held / 2));
        assertEq(token.balanceOf(bob), held / 2);
        assertEq(token.balanceOf(alice), held - held / 2);
    }

    function test_unknownSelectorAndPlainEtherRevert() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    // Fuzz: conservation
    // ─────────────────────────────────────────────────────────────────────────────────────────────

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer) + token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientBalance.selector, deployer, SUPPLY, amount));
        vm.prank(deployer);
        token.transfer(alice, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        if (amount > allowed) {
            vm.expectRevert(abi.encodeWithSelector(ScoopToken.InsufficientAllowance.selector, spender, allowed, amount));
            token.transferFrom(deployer, alice, amount);
        } else {
            assertTrue(token.transferFrom(deployer, alice, amount));
            assertEq(token.allowance(deployer, spender), allowed - amount);
            assertEq(token.balanceOf(alice), amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }
}
