// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Permissionless ERC-4626 over `MockUSDC`.
/// @dev OZ's `ERC4626` is `abstract`, so groups 2 and 4 cannot instantiate it
/// directly -- this concrete subclass is what they deploy. Deliberately has no
/// allowlist: it is the control against which `AllowlistedERC4626`'s gate is the
/// variable.
contract MockVault is ERC4626 {
    constructor(IERC20 asset_) ERC20("Mock Vault", "mVAULT") ERC4626(asset_) {}
}
