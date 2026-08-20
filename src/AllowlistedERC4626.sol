// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title AllowlistedERC4626
/// @notice A minimal KYC-gated ERC-4626, standing in for the operator's vault.
///
/// @dev The only component in this design beyond the strict minimum, and it earns
/// its place by one present requirement: the demo must show the *vault itself*
/// rejecting an agent that skips the router. That is the load-bearing claim of the
/// pitch, and no permissionless vault can demonstrate it.
///
/// **The gate is on `receiver`, not on `caller`.** Anyone may push assets in; only an
/// allowlisted address may end up holding the shares. That mirrors how an operator's
/// real vault gates -- their KYC list is a list of who may hold a position, not of
/// who may submit a transaction.
///
/// **Holds USDC idle.** Group 3's escape hatch fixed a wall-clock trigger at end of
/// 2026-08-18 for the Morpho Blue integration, and an unevaluated trigger means the
/// hatch is taken by default. Idle is inherited for free: OZ's `totalAssets()`
/// already returns this contract's asset balance. Morpho exposure lives only in the
/// mainnet fork suite, against a real MetaMorpho vault.
contract AllowlistedERC4626 is ERC4626, Ownable {
    /// @notice The eighth and last custom error in the design; the only one that is
    /// not the router's. The receiver is echoed back because it is the whole point --
    /// `NotAllowlisted(agent)` names who was rejected, not merely that someone was.
    error NotAllowlisted(address receiver);

    event AllowlistUpdated(address indexed account, bool allowed);

    /// @notice The operator's KYC list: who may hold a position in this vault.
    mapping(address account => bool) public allowlisted;

    constructor(IERC20 asset_, string memory name_, string memory symbol_, address initialOwner)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(initialOwner)
    {}

    /// @notice Add or remove an address from the KYC list.
    /// @dev The minimal admin surface. Group 4 needs it for owner B, and group 5's
    /// deploy script needs it for the principal before demo transaction 1.
    function setAllowlisted(address account, bool allowed) external onlyOwner {
        allowlisted[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    /// @dev Reverts **before** delegating to the inherited implementation, and that
    /// ordering is the entire point of decision 6. OZ 5.x `ERC4626.deposit` reads
    /// `maxDeposit(receiver)` on its first line and reverts
    /// `ERC4626ExceededMaxDeposit`, so expressing the allowlist *through*
    /// `maxDeposit` -- the spec-compliant way -- would make `NotAllowlisted`
    /// unreachable and silently kill the demo's closing transaction.
    ///
    /// Firing before any `transferFrom` is also what makes the suite-wide
    /// containment invariant hold: no test ever needs to deal the agent USDC.
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (!allowlisted[receiver]) revert NotAllowlisted(receiver);
        return super.deposit(assets, receiver);
    }

    /// @dev Same gate, same ordering. OZ's `mint` reads `maxMint(receiver)` first and
    /// reverts `ERC4626ExceededMaxMint`, symmetrically with `deposit`.
    function mint(uint256 shares, address receiver) public override returns (uint256) {
        if (!allowlisted[receiver]) revert NotAllowlisted(receiver);
        return super.mint(shares, receiver);
    }

    /// @dev Returns 0 for a non-allowlisted receiver for ERC-4626 conformance -- an
    /// integrator reading `maxDeposit` should see the gate. It must NOT be the
    /// mechanism that produces the revert reason; the override above fires first.
    function maxDeposit(address receiver) public view override returns (uint256) {
        return allowlisted[receiver] ? super.maxDeposit(receiver) : 0;
    }

    /// @dev Conformance only. See `maxDeposit`.
    function maxMint(address receiver) public view override returns (uint256) {
        return allowlisted[receiver] ? super.maxMint(receiver) : 0;
    }
}
