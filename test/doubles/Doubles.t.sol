// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.sol";
import {MinimalIdentityRegistry, ZeroOwnerRegistry} from "./MinimalIdentityRegistry.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockVault} from "./MockVault.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Inner harness used only by the negative containment tests.
/// @dev It inherits `BaseTest` and is DEPLOYED by the outer test, so its storage is
/// separate -- which is why the slots are assigned through a setter rather than in a
/// `setUp`. Each function below carries the modifier and then deliberately violates
/// it, so the assertion failure is the asserted outcome rather than a red suite.
contract ContainmentHarness is BaseTest {
    function wire(address agent_, address router_, IERC20 asset_, IERC20 share_) external {
        agent = agent_;
        containedRouter = router_;
        containedAsset = asset_;
        containedShare = share_;
    }

    function leakAssetToAgent(uint256 amount) external containment {
        require(containedAsset.transfer(agent, amount), "harness: asset transfer failed");
    }

    function leakShareToRouter(uint256 amount) external containment {
        require(containedShare.transfer(containedRouter, amount), "harness: share transfer failed");
    }

    function noop() external containment {}
}

/// @notice Asserts that the group 1 doubles and the `BaseTest` fixture behave the way
/// every later group assumes. Without this file, group 1's gate is `forge build`
/// alone and four of its acceptance criteria are asserted by nothing.
///
/// @dev These tests leak the asset ON PURPOSE inside a reverting sub-call, which is
/// why group 4's suite-wide containment audit explicitly scopes this file out.
contract DoublesTest is Test {
    MinimalIdentityRegistry internal registry;
    ZeroOwnerRegistry internal zeroRegistry;
    MockUSDC internal usdc;
    MockVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal agentAddr = makeAddr("agent");
    address internal routerAddr = makeAddr("router");

    uint256 internal constant AGENT_ID = 42;

    function setUp() public {
        registry = new MinimalIdentityRegistry();
        zeroRegistry = new ZeroOwnerRegistry();
        usdc = new MockUSDC();
        vault = new MockVault(IERC20(address(usdc)));
    }

    // ---------------------------------------------------------------------
    // Acceptance criterion 2 -- the resolved OpenZeppelin version is 5.x
    // ---------------------------------------------------------------------

    /// @dev A genuine discriminator, unlike `ECDSA.RecoverError` or `IERC4626` --
    /// both of which resolve fine under 4.9.x and would pass while proving nothing.
    ///
    /// `tryRecover` returns `(address, RecoverError)` in 4.9.x and
    /// `(address, RecoverError, bytes32)` in 5.x, so this THREE-component destructure
    /// simply does not compile against 4.x.
    function test_OpenZeppelinIsFiveX() public pure {
        (address recovered, ECDSA.RecoverError err, bytes32 errArg) = ECDSA.tryRecover(bytes32(uint256(1)), hex"");

        assertEq(recovered, address(0));
        assertTrue(err == ECDSA.RecoverError.InvalidSignatureLength);
        assertEq(errArg, bytes32(0));

        // Exists only in 5.x, and is declared INSIDE `abstract contract ERC4626`, so
        // it has to be reached through the contract rather than written bare.
        assertEq(
            ERC4626.ERC4626ExceededMaxDeposit.selector,
            bytes4(keccak256("ERC4626ExceededMaxDeposit(address,uint256,uint256)"))
        );
    }

    // ---------------------------------------------------------------------
    // Acceptance criteria 3 and 4 -- the registry doubles
    // ---------------------------------------------------------------------

    function test_RegistryRevertsForUnmintedId() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, AGENT_ID));
        registry.ownerOf(AGENT_ID);
    }

    function test_ZeroOwnerRegistryReturnsZeroForUnmintedId() public view {
        // The whole point of the double: address(0) instead of a revert, so the
        // router has to turn it into AgentNotRegistered rather than verifying a
        // signature against a zero principal.
        assertEq(zeroRegistry.ownerOf(AGENT_ID), address(0));
    }

    function test_AgentIdMintsAndTransfers() public {
        registry.mint(alice, AGENT_ID);
        assertEq(registry.ownerOf(AGENT_ID), alice);

        vm.prank(alice);
        registry.transferFrom(alice, bob, AGENT_ID);

        // The operation five downstream criteria are built on.
        assertEq(registry.ownerOf(AGENT_ID), bob);
    }

    // ---------------------------------------------------------------------
    // Acceptance criterion 5 -- the token doubles
    // ---------------------------------------------------------------------

    function test_MockUSDCIsSixDecimalsAndMintable() public {
        assertEq(usdc.decimals(), 6);

        usdc.mint(alice, 1_000e6);
        assertEq(usdc.balanceOf(alice), 1_000e6);
    }

    function test_MockVaultIsInstantiableAndUsable() public {
        // OZ's ERC4626 is abstract; this proves the concrete subclass works, which
        // is what groups 2 and 4 depend on.
        assertEq(vault.asset(), address(usdc));

        // OZ 5.x: decimals() is _underlyingDecimals + _decimalsOffset(), offset 0 by
        // default, so shares here are 6-decimal -- unlike mwUSDC's 18.
        assertEq(vault.decimals(), 6);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        uint256 shares = vault.deposit(100e6, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
    }

    // ---------------------------------------------------------------------
    // Acceptance criterion 6 -- the containment modifier is ARMED, not merely
    // declared. Three permanent negative tests.
    // ---------------------------------------------------------------------

    /// @dev Deploys the harness, funds it with both legs, and wires its slots.
    function _armedHarness() internal returns (ContainmentHarness harness) {
        harness = new ContainmentHarness();
        harness.wire(agentAddr, routerAddr, IERC20(address(usdc)), IERC20(address(vault)));

        // Fund the asset leg directly.
        usdc.mint(address(harness), 10e6);

        // Fund the share leg by depositing on the harness's behalf.
        usdc.mint(address(this), 10e6);
        usdc.approve(address(vault), 10e6);
        vault.deposit(10e6, address(harness));
    }

    /// (a) leaks the ASSET to the agent.
    function test_ContainmentCatchesAssetLeakToAgent() public {
        ContainmentHarness harness = _armedHarness();

        vm.expectRevert();
        harness.leakAssetToAgent(1);
    }

    /// (b) leaks ONE SHARE to the router -- the only test that arms the share leg and
    /// the router leg at all. Without it, a modifier that checked only assets on only
    /// the agent would pass every test in this wish while asserting a quarter of what
    /// it claims.
    function test_ContainmentCatchesShareLeakToRouter() public {
        ContainmentHarness harness = _armedHarness();

        vm.expectRevert();
        harness.leakShareToRouter(1);
    }

    /// (c) leaves `agent` unset. address(0) has trivially zero balances, so without
    /// the mandatory-slot guard this would pass while checking nobody.
    function test_ContainmentRejectsUnsetAgent() public {
        ContainmentHarness harness = new ContainmentHarness();
        harness.wire(address(0), routerAddr, IERC20(address(usdc)), IERC20(address(vault)));

        vm.expectRevert("BaseTest: agent unset");
        harness.noop();
    }

    /// @dev The positive control for (a)-(c): a correctly wired, non-leaking harness
    /// passes. Without this, all three negative tests would still pass against a
    /// modifier that unconditionally reverted.
    function test_ContainmentPassesWhenNothingLeaks() public {
        ContainmentHarness harness = _armedHarness();
        harness.noop();
    }
}
