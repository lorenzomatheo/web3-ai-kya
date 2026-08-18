// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal ERC-20 standing in for USDC.
/// @dev The decimals matter: the router performs no conversion, so `cap` and the
/// `assets` argument are in 6-decimal units end to end (asserted in group 2).
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @dev Unpermissioned: group 4 needs to fund owner B.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
