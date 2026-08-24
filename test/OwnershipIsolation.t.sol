// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.sol";
import {MandateRouter} from "../src/MandateRouter.sol";
import {AllowlistedERC4626} from "../src/AllowlistedERC4626.sol";
import {MinimalIdentityRegistry} from "./doubles/MinimalIdentityRegistry.sol";
import {MockUSDC} from "./doubles/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Group 4's LOCAL half. No RPC, no fork, no network.
///
/// @dev Deliberately outside `test/fork/` for two reinforcing reasons. The default
/// profile excludes `test/fork/**`, so putting these here would hide them from the
/// very bare `forge test` run that the suite-wide containment criterion depends on.
/// And the schedule mitigation -- "the trimmable subset is the mainnet-fork half of
/// group 4 only" -- is executable *by path* precisely because the trimmable tests are
/// exactly the contents of `MandateRouterFork.t.sol` and nothing else.
///
/// These carry the only proof of decision 17's **cross-owner** half: that A's `spent`
/// does not charge B, and that A's revocation does not blacklist B's byte-identical
/// struct. Group 2's single-owner revocation tests cannot reach either.
///
/// Runs against `AllowlistedERC4626`, which `mwUSDC` cannot stand in for since it has
/// no allowlist.
contract OwnershipIsolationTest is BaseTest {
    MinimalIdentityRegistry internal registry;
    MockUSDC internal usdc;
    AllowlistedERC4626 internal vault;
    MandateRouter internal router;

    address internal ownerA;
    uint256 internal ownerAPk;
    address internal ownerB;
    uint256 internal ownerBPk;
    address internal admin = makeAddr("admin");

    uint256 internal constant AGENT_ID = 7;
    uint256 internal constant CAP = 1_000e6;

    uint64 internal expiry;

    bytes32 internal constant TYPEHASH =
        keccak256("Mandate(uint256 agentId,address agent,address target,uint256 cap,uint64 expiry,uint256 nonce)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() public {
        (ownerA, ownerAPk) = makeAddrAndKey("ownerA");
        (ownerB, ownerBPk) = makeAddrAndKey("ownerB");
        agent = makeAddr("agent");

        registry = new MinimalIdentityRegistry();
        usdc = new MockUSDC();
        vault = new AllowlistedERC4626(IERC20(address(usdc)), "Allowlisted USDC Vault", "aUSDC", admin);
        router = new MandateRouter(address(registry), address(vault));

        registry.mint(ownerA, AGENT_ID);
        expiry = uint64(block.timestamp + 30 days);

        // Owner B is underwritten INDEPENDENTLY. The agentId transfer re-keys router
        // state but carries no KYC, so the operator must have allowlisted B on their
        // own account -- funded and approved separately from A.
        vm.startPrank(admin);
        vault.setAllowlisted(ownerA, true);
        vault.setAllowlisted(ownerB, true);
        vm.stopPrank();

        _fundAndApprove(ownerA);
        _fundAndApprove(ownerB);

        containedRouter = address(router);
        containedAsset = IERC20(address(usdc));
        containedShare = IERC20(address(vault));
    }

    function _fundAndApprove(address who) internal {
        usdc.mint(who, 100_000e6);
        vm.startPrank(who);
        usdc.approve(address(router), type(uint256).max);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Byte-identical across owners: nothing in the struct names the principal,
    /// which is decision 4 and exactly why the storage key must carry the account.
    function _mandate(uint256 nonce) internal view returns (MandateRouter.Mandate memory) {
        return MandateRouter.Mandate({
            agentId: AGENT_ID, agent: agent, target: address(vault), cap: CAP, expiry: expiry, nonce: nonce
        });
    }

    function _digest(MandateRouter.Mandate memory m) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("MandateRouter")),
                keccak256(bytes("1")),
                block.chainid,
                address(router)
            )
        );
        bytes32 structHash = keccak256(abi.encode(TYPEHASH, m.agentId, m.agent, m.target, m.cap, m.expiry, m.nonce));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    function _sign(MandateRouter.Mandate memory m, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(m));
        return abi.encodePacked(r, s, v);
    }

    function _transferAgentId(address from, address to) internal {
        vm.prank(from);
        registry.transferFrom(from, to, AGENT_ID);
    }

    // ------------------------------------------------------------------
    // State isolation across ownership -- decision 17's cross-owner half
    // ------------------------------------------------------------------

    /// @dev Under a hash-only key this reverts `ExceedsMandate(200, 1000)`, charging
    /// B for A's spending. No `vm.warp` anywhere: a byte-identical struct fixes the
    /// expiry, so warping past it would fail the test for the wrong reason.
    function test_OwnerASpendingDoesNotChargeOwnerB() public containment {
        MandateRouter.Mandate memory m = _mandate(1);

        vm.prank(agent);
        router.depositFor(m, _sign(m, ownerAPk), 800e6);

        _transferAgentId(ownerA, ownerB);

        // Byte-identical mandate, signed by B this time. Under a hash-only key this
        // is the call that reverts ExceedsMandate(200, 1000), charging B for A's
        // spending -- so the deposit itself is the assertion, and the bookkeeping
        // checks below are deliberately AFTER it rather than before.
        vm.prank(agent);
        router.depositFor(m, _sign(m, ownerBPk), 1_000e6);

        assertEq(vault.balanceOf(ownerB), vault.previewDeposit(1_000e6), "B's shares are B's");
        assertEq(router.spent(router.mandateKey(_digest(m), ownerB)), 1_000e6, "B gets a full fresh cap");
        assertEq(router.spent(router.mandateKey(_digest(m), ownerA)), 800e6, "A's counter untouched");
    }

    /// @dev A's revocation is a withdrawal of A's signature, not a permanent
    /// blacklisting of a byte pattern. B has issued a fresh authorization with their
    /// own key, so the identical struct must still work for B.
    function test_OwnerARevocationDoesNotBlacklistOwnerB() public containment {
        MandateRouter.Mandate memory m = _mandate(2);

        vm.prank(ownerA);
        router.revoke(m);

        // A's own deposit is dead.
        vm.prank(agent);
        vm.expectRevert(MandateRouter.MandateRevoked.selector);
        router.depositFor(m, _sign(m, ownerAPk), 100e6);

        _transferAgentId(ownerA, ownerB);

        vm.prank(agent);
        router.depositFor(m, _sign(m, ownerBPk), 500e6);

        assertEq(vault.balanceOf(ownerB), vault.previewDeposit(500e6), "B's byte-identical struct is accepted");
        assertTrue(router.revoked(router.mandateKey(_digest(m), ownerA)), "A's revocation still stands for A");
        assertFalse(router.revoked(router.mandateKey(_digest(m), ownerB)), "and never applied to B");
    }

    // ------------------------------------------------------------------
    // Containment: losing agent authority never costs access to a position
    // ------------------------------------------------------------------

    /// @dev Holds by construction only because the router never custodies -- the
    /// shares were minted straight to A and are A's to redeem regardless of who owns
    /// the agentId now.
    function test_PriorOwnerStillRedeemsDirectlyAfterTransfer() public containment {
        MandateRouter.Mandate memory m = _mandate(3);

        vm.prank(agent);
        uint256 shares = router.depositFor(m, _sign(m, ownerAPk), 600e6);

        _transferAgentId(ownerA, ownerB);

        uint256 before = usdc.balanceOf(ownerA);
        vm.prank(ownerA);
        uint256 assets = vault.redeem(shares, ownerA, ownerA);

        assertEq(assets, 600e6, "A exits their own position in full");
        assertEq(usdc.balanceOf(ownerA), before + 600e6, "assets back to A");
        assertEq(vault.balanceOf(ownerA), 0, "position closed");
    }

    // ------------------------------------------------------------------
    // Risk 12 -- pinned as a proven property, not an assumption
    // ------------------------------------------------------------------

    /// @dev The principal deposits DIRECTLY into the vault, never touching the router.
    /// The agent then redeems those shares under a same-principal, different-`nonce`
    /// mandate through which no deposit was ever routed -- so a `sharesMinted` counter
    /// under it would read zero -- and it is accepted.
    ///
    /// The mandate must be the same principal's: under a different owner's mandate the
    /// derived principal differs and `redeem` would burn that other owner's shares,
    /// which tests nothing.
    ///
    /// Written to PASS today, so that adding a `sharesMinted` bound later has a test
    /// to invert rather than a paragraph to reinterpret.
    function test_Risk12_MandateReachesSharesItDidNotCreate() public containment {
        // A acquires a position with no router involvement whatsoever.
        vm.startPrank(ownerA);
        usdc.approve(address(vault), 400e6);
        uint256 shares = vault.deposit(400e6, ownerA);
        vm.stopPrank();

        // A mandate under a nonce through which nothing was ever routed.
        MandateRouter.Mandate memory unused = _mandate(99);
        assertEq(router.spent(router.mandateKey(_digest(unused), ownerA)), 0, "no deposit ever routed under it");

        uint256 before = usdc.balanceOf(ownerA);
        vm.prank(agent);
        uint256 assets = router.redeemFor(unused, _sign(unused, ownerAPk), shares);

        // Accepted. This is the gap, proven rather than assumed.
        assertEq(assets, 400e6, "the agent reached a position the mandate did not create");
        assertEq(usdc.balanceOf(ownerA), before + 400e6, "assets still arrive at the principal");
        assertEq(vault.balanceOf(ownerA), 0, "the whole unrelated position was exitable");
    }
}
