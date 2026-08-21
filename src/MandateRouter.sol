// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title MandateRouter
/// @notice On-chain proof that an agent address acts for a KYC'd principal, within
/// limits the principal signed off-chain.
///
/// @dev **Pass-through, not a wrapping vault.** The router verifies the mandate and
/// then calls `vault.deposit(assets, principal)` so the vault mints directly to the
/// principal. The router's balance is zero before and after; it holds value only
/// between `transferFrom` and `deposit` inside one call.
///
/// Non-upgradeable, ownerless, no arbitrary-call path, no fee logic, no pause
/// (decision 11). It holds standing ERC-20 allowances, and that blast radius is only
/// acceptable if the code cannot change and cannot be steered.
contract MandateRouter is EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The authorization a principal signs off-chain.
    /// @dev The principal is deliberately NOT a field: it is derived from
    /// `registry.ownerOf(agentId)` and must equal the recovered signer (decision 4).
    /// That is what binds the ERC-8004 identity to the authorization rather than
    /// merely mentioning it, and it makes an `agentId` transfer self-revoking.
    ///
    /// The field is `target`, not `vault`, because it sits inside the EIP-712
    /// typehash -- the one part of this design that cannot be changed later for free
    /// (decision 15). Renaming it after any mandate is signed invalidates every
    /// outstanding signature.
    struct Mandate {
        uint256 agentId; // ERC-8004 token id; ownerOf() gives the principal
        address agent; // the only address permitted to call
        address target; // scope: this contract and no other; a vault in v0.1
        uint256 cap; // cumulative, in USDC units (6 dp)
        uint64 expiry;
        uint256 nonce; // distinguishes otherwise-identical mandates
    }

    /// @dev Byte-for-byte the type string the demo script must reproduce. A mismatch
    /// anywhere in it -- or in the domain below -- surfaces only as
    /// `InvalidSignature`, indistinguishable from a genuinely bad signature.
    bytes32 private constant MANDATE_TYPEHASH =
        keccak256("Mandate(uint256 agentId,address agent,address target,uint256 cap,uint64 expiry,uint256 nonce)");

    // Step 1: the caller is not the agent named in the mandate.
    error NotAgent();
    // Step 2: the mandate authorizes a different target than this router's vault.
    error WrongVault();
    // Step 3: the mandate is past its expiry, in either direction (decision 14).
    error MandateExpired();
    // Step 4: `ownerOf` reverted, or returned the zero address.
    error AgentNotRegistered();
    // Step 5: malformed, malleable, or signed by someone other than the principal.
    error InvalidSignature();
    // Step 6: this mandate was revoked by its signer.
    error MandateRevoked();
    // Step 7: deposit would exceed the cumulative cap. Reports headroom, not the cap.
    error ExceedsMandate(uint256 remaining, uint256 attempted);

    event Deposited(
        bytes32 indexed mandateHash,
        address indexed principal,
        uint256 indexed agentId,
        address agent,
        uint256 assets,
        uint256 shares,
        uint256 spentTotal
    );

    event Redeemed(
        bytes32 indexed mandateHash,
        address indexed principal,
        uint256 indexed agentId,
        address agent,
        uint256 shares,
        uint256 assets
    );

    /// @dev Named `Revoked` rather than `MandateRevoked` because that name is already
    /// the custom error above, and Solidity will not accept both in one contract.
    ///
    /// This is the one log that is NOT attribution. Its second field is `revoker`,
    /// not `principal`, because `revoke` performs no registry lookup -- so
    /// `msg.sender` is the only address it can honestly emit. Its `agentId` is
    /// caller-supplied and unvalidated: an indexing hint, never attribution.
    /// Consumption rule: a `Revoked` log is authoritative only for mandates whose
    /// recovered signer equals `revoker`.
    event Revoked(bytes32 indexed mandateHash, address indexed revoker, uint256 indexed agentId);

    /// @notice ERC-8004 agent identity. Only `ownerOf` is ever consumed.
    IERC721 public immutable registry;

    /// @notice The single vault this router is scoped to. `m.target` must equal it.
    IERC4626 public immutable vault;

    /// @notice The vault's underlying asset. Read once at construction.
    IERC20 public immutable asset;

    /// @notice Cumulative assets deposited under `(mandateHash, principal)`.
    /// @dev Read AND written at the derived principal. Monotonic -- redemption never
    /// decreases it, so round trips permanently consume budget.
    mapping(bytes32 key => uint256 assets) public spent;

    /// @notice Whether `(mandateHash, account)` has been revoked.
    /// @dev **Written at `msg.sender`, read at the derived principal** (decision 17).
    /// The asymmetry is the entire mechanism, in both directions:
    ///
    /// - Writing at the derived principal instead would let anyone holding a copy of
    ///   the mandate revoke it on the owner's behalf.
    /// - Reading at `msg.sender` instead would make the kill switch permanently
    ///   inert, since step 1 has already forced `msg.sender == m.agent` on every
    ///   path that reads it, while the legitimate revoker -- the principal -- wrote
    ///   under their own address.
    ///
    /// One-way: there is no un-revoke. A signer who wants the same terms back must
    /// sign a fresh `nonce`.
    mapping(bytes32 key => bool) public revoked;

    /// @param registry_ ERC-8004 identity registry. Must have code.
    /// @param vault_ The ERC-4626 this router is scoped to. Must have code.
    /// @dev Both are constructor parameters rather than constants because the
    /// registry is live on Base Sepolia but unusable on Base mainnet, so the two
    /// environments must differ by config, not by code (decision 7).
    ///
    /// The code checks are plain `require`s, not custom errors, deliberately: the
    /// product's error surface is exactly eight custom errors and this constructor
    /// path is not one of them. They exist because a registry address with no code
    /// reverts on Solidity's `extcodesize` check inside our own frame, which the
    /// try/catch in `_verify` cannot catch -- so it has to be caught here instead.
    constructor(address registry_, address vault_) EIP712("MandateRouter", "1") {
        require(registry_.code.length != 0, "MandateRouter: registry has no code");
        require(vault_.code.length != 0, "MandateRouter: vault has no code");

        registry = IERC721(registry_);
        vault = IERC4626(vault_);
        asset = IERC20(IERC4626(vault_).asset());
    }

    /// @notice Deposit `assets` of the vault's underlying on the principal's behalf.
    /// @dev Runs all seven checks. The cap is a deposit-side instrument only.
    /// @return shares Minted to the principal, never to this router.
    function depositFor(Mandate calldata m, bytes calldata sig, uint256 assets)
        external
        nonReentrant
        returns (uint256 shares)
    {
        (address principal, bytes32 digest, bytes32 key) = _verify(m, sig);

        // Step 7. Reports remaining headroom rather than echoing the static cap.
        //
        // Written as a subtraction on the LEFT of the comparison, never as
        // `alreadySpent + assets > m.cap`. `assets` is agent-supplied and unbounded,
        // so the addition form overflows under 0.8 checked arithmetic inside the
        // check itself and hands a legitimate caller `Panic(0x11)` instead of this
        // error -- the one thing the design calls the product. The subtraction cannot
        // underflow: `spent[key]` is only ever written below, as a value this same
        // check has already bounded by `m.cap`, and `m.cap` is fixed for a given
        // `key` because the key is the EIP-712 digest, which commits to `cap`.
        uint256 alreadySpent = spent[key];
        uint256 remaining = m.cap - alreadySpent;
        if (assets > remaining) {
            revert ExceedsMandate(remaining, assets);
        }
        uint256 spentTotal = alreadySpent + assets;

        // Effect before the vault interaction. Full checks-effects-interactions is
        // not reachable here -- `registry.ownerOf` inside `_verify` is an external
        // call that must precede this write, because budget may only be consumed
        // after the signature is verified and the signer can only be known by asking
        // the registry. `nonReentrant` covers the residue and is load-bearing.
        spent[key] = spentTotal;

        // From the principal, never from the agent. This is the whole basis of the
        // containment claim.
        asset.safeTransferFrom(principal, address(this), assets);
        asset.forceApprove(address(vault), assets);

        // Shares mint straight to the principal; no decimals conversion anywhere.
        shares = vault.deposit(assets, principal);

        emit Deposited(digest, principal, m.agentId, m.agent, assets, shares, spentTotal);
    }

    /// @notice Redeem `shares` of the principal's position back to the principal.
    /// @dev Runs checks 1 through 6 -- everything except the cap, which is skipped
    /// not because the exit side is safe but because no quantity bound separates a
    /// forced exit from a legitimate one (decision 3). `spent` is unchanged.
    /// @return assets Delivered to the principal, never to the agent or this router.
    function redeemFor(Mandate calldata m, bytes calldata sig, uint256 shares)
        external
        nonReentrant
        returns (uint256 assets)
    {
        (address principal, bytes32 digest,) = _verify(m, sig);

        // Both `receiver` and `owner` are hard-coded to the derived principal. That
        // defeats theft -- no value can leave the principal's control -- though not
        // grief. The router must never pass any other `owner`.
        assets = vault.redeem(shares, principal, principal);

        emit Redeemed(digest, principal, m.agentId, m.agent, shares, assets);
    }

    /// @notice Kill a mandate you signed. No ownership gate, by design.
    ///
    /// @dev Keyed on `msg.sender`, which looks unauthenticated and is not: the value
    /// paths read `revoked` at the principal derived from the registry, and step 5
    /// independently forces the recovered signer to equal that same principal, so an
    /// entry written by anyone who did not sign the mandate sits at a key no path
    /// ever reads. Third-party DoS is prevented by the key binding, not by a gate.
    ///
    /// Dropping the gate is what makes revocation *reliable*. A gate of
    /// `msg.sender == registry.ownerOf(m.agentId)` would strand a principal who
    /// transferred the `agentId` away and can no longer kill a signature they
    /// themselves produced -- and if the `agentId` ever came back, that mandate would
    /// go live again against a still-standing allowance. Keying on the caller also
    /// takes `registry.ownerOf` off the emergency path, so revocation still works
    /// when the registry proxy is bricked or the agent NFT has been burned.
    ///
    /// Takes the full `Mandate` rather than its hash so the router recomputes the
    /// digest itself. Under `msg.sender` keying a caller-supplied hash could write
    /// `revoked[(wrongHash, you)]` -- reverting nothing and emitting a log that looks
    /// correct. A silent no-op is the worst available failure mode for a kill switch.
    function revoke(Mandate calldata m) external {
        bytes32 digest = _digest(m);

        revoked[keccak256(abi.encode(digest, msg.sender))] = true;

        emit Revoked(digest, msg.sender, m.agentId);
    }

    /// @notice The EIP-712 digest for `m`, as signed and as keyed on.
    /// @dev Exposed so the demo and any indexer can reproduce the storage key
    /// off-chain without re-implementing the domain separator.
    function mandateDigest(Mandate calldata m) external view returns (bytes32) {
        return _digest(m);
    }

    /// @notice The storage key for `spent` and `revoked`.
    function mandateKey(bytes32 digest, address account) external pure returns (bytes32) {
        return keccak256(abi.encode(digest, account));
    }

    /// @dev Steps 1 through 6, in one place, called by both value paths. Sharing it
    /// is the point: a second copy inside `redeemFor` would drift.
    function _verify(Mandate calldata m, bytes calldata sig)
        internal
        view
        returns (address principal, bytes32 digest, bytes32 key)
    {
        // 1. Only the named agent may call.
        if (msg.sender != m.agent) revert NotAgent();

        // 2. The mandate is scoped to exactly one target.
        if (m.target != address(vault)) revert WrongVault();

        // 3. Inclusive of the expiry second. Enforced on redemption too (decision 14):
        //    expiry means the agent's authority ended, not merely that it cannot add.
        // Validator drift is ~seconds against expiries measured in hours or days, and
        // decision 14 wants expiry to mean "authority ended", not a precise instant.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > m.expiry) revert MandateExpired();

        // 4. Derive the principal. try/catch because ERC-721 `ownerOf` reverts
        //    `ERC721NonexistentToken` for an unminted id, and decision 9 requires the
        //    revert reason to be ours. The zero check is not redundant: a
        //    non-conformant registry that returns address(0) instead of reverting
        //    would otherwise reach step 5 and pass against garbage.
        try registry.ownerOf(m.agentId) returns (address owner_) {
            if (owner_ == address(0)) revert AgentNotRegistered();
            principal = owner_;
        } catch {
            revert AgentNotRegistered();
        }

        digest = _digest(m);

        // 5. `tryRecover`, not `recover`: the latter reverts with OZ's own
        //    `ECDSAInvalidSignature*`. The 3-tuple is 5.x-only, and `err` must be
        //    checked -- taking the address alone yields address(0) on a malformed
        //    signature, which step 4's zero check exists to make unreachable.
        //    `tryRecover` also rejects malleable high-`s` signatures, via
        //    `RecoverError.InvalidSignatureS`.
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, sig);
        if (err != ECDSA.RecoverError.NoError || signer != principal) revert InvalidSignature();

        // The digest, not the bare struct hash: it folds in `chainId` and
        // `verifyingContract`, extending replay protection from the signature to the
        // state keyed by it.
        key = keccak256(abi.encode(digest, principal));

        // 6. Read at the derived principal. See the `revoked` docs above.
        if (revoked[key]) revert MandateRevoked();
    }

    function _digest(Mandate calldata m) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(MANDATE_TYPEHASH, m.agentId, m.agent, m.target, m.cap, m.expiry, m.nonce))
        );
    }
}
