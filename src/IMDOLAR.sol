// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title IMDOLAR (DOLAR)
/// @notice Mints one billion tokens once. Every outgoing PoolManager transfer burns a 99% tax.
/// @dev A buy is defined by its source, not its caller or recipient. The rule also taxes liquidity
/// withdrawals and other outgoing transfers from the configured manager. Other venues are outside
/// this definition; ERC-20 transfers cannot identify arbitrary economic purchases.
contract IMDOLAR is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant BUY_TAX_BPS = 9_900;

    address public immutable poolManager;

    error InvalidPoolManager(address manager);

    /// @param poolManager_ The already deployed launch PoolManager. This address cannot be changed.
    /// @dev The complete initial supply belongs to msg.sender, including when deployed by a factory.
    constructor(address poolManager_) ERC20("IMDOLAR", "DOLAR") {
        if (
            poolManager_ == address(0) || poolManager_ == msg.sender
                || poolManager_ == address(this) || poolManager_.code.length == 0
        ) revert InvalidPoolManager(poolManager_);

        poolManager = poolManager_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @dev Round the buyer's 1% down: fee = ceil(gross * 99 / 100). This avoids a zero-tax dust
    /// transfer and multiplication overflow. Calling the base implementation prevents recursive tax.
    /// There are no external calls, recipient exemptions, setters, or privileged transfer paths.
    function _update(address from, address to, uint256 amount) internal override {
        if (from == poolManager && amount != 0) {
            uint256 net = amount / 100;
            super._update(from, address(0), amount - net);
            super._update(from, to, net);
        } else {
            super._update(from, to, amount);
        }
    }
}
