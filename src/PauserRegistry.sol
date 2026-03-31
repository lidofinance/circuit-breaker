// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

/// @title  PauserRegistry
/// @author Lido
/// @notice Library for managing an enumerable pausable-pauser registry.
library PauserRegistry {
    // =========================================================================
    // Types
    // =========================================================================

    struct Storage {
        mapping(address pausable => address) pauser;
        /// @dev 1-based index into pausables array; 0 means not present.
        mapping(address pausable => uint256) index;
        /// @dev Number of pausables assigned to a pauser.
        mapping(address pauser => uint256) pausableCount;
        address[] pausables;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event PauserSet(address indexed pausable, address indexed previousPauser, address indexed pauser);

    // =========================================================================
    // Errors
    // =========================================================================

    error PausableIsZero();
    error PauserIsAlreadyZero();

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Return the pauser registered for a pausable.
    /// @param  _pausable Pausable contract address.
    function getPauser(Storage storage _self, address _pausable) internal view returns (address) {
        return _self.pauser[_pausable];
    }

    /// @notice Return all pausable addresses currently registered.
    function getPausables(Storage storage _self) internal view returns (address[] memory) {
        return _self.pausables;
    }

    /// @notice Return whether an address is currently registered for at least one pausable.
    /// @param  _pauser Address to check.
    function isRegistered(Storage storage _self, address _pauser) internal view returns (bool) {
        return _self.pausableCount[_pauser] > 0;
    }

    // =========================================================================
    // Mutative functions
    // =========================================================================

    /// @notice Register, replace, or unregister a pauser for a pausable.
    /// @param  _pausable Pausable contract address.
    /// @param  _pauser   New pauser address. Use address(0) to unregister.
    function setPauser(Storage storage _self, address _pausable, address _pauser) internal {
        require(_pausable != address(0), PausableIsZero());

        // Cache storage for gas efficiency.
        mapping(address => address) storage pauser = _self.pauser;
        mapping(address => uint256) storage index = _self.index;
        mapping(address => uint256) storage pausableCount = _self.pausableCount;
        address[] storage pausables = _self.pausables;

        address previousPauser = pauser[_pausable];
        bool isNewPausable = previousPauser == address(0);
        bool isRemovingPauser = _pauser == address(0);

        // Cannot remove a pauser if no pauser is set.
        // Using manual revert instead of require to avoid inverted boolean logic
        if (isNewPausable && isRemovingPauser) revert PauserIsAlreadyZero();

        // Update the pauser.
        pauser[_pausable] = _pauser;

        // Update pausable counts.
        if (!isNewPausable) --pausableCount[previousPauser];
        if (!isRemovingPauser) ++pausableCount[_pauser];

        // Add pausable to the set if not present.
        if (isNewPausable) {
            pausables.push(_pausable);
            index[_pausable] = pausables.length;
        }

        // Remove pausable from the set if the pauser is removed.
        if (isRemovingPauser) {
            uint256 removedIndex = index[_pausable];
            address lastPausable = pausables[pausables.length - 1];

            pausables[removedIndex - 1] = lastPausable;
            index[lastPausable] = removedIndex;

            pausables.pop();
            delete index[_pausable];
        }

        emit PauserSet(_pausable, previousPauser, _pauser);
    }
}
