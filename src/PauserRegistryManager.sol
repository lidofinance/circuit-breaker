// SPDX-FileCopyrightText: 2026 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.34;

/// @title  PauserRegistryManager
/// @author Lido
/// @notice Library for managing an enumerable pausable-pauser registry.
library PauserRegistryManager {
    // =========================================================================
    // Types
    // =========================================================================

    struct PauserRegistry {
        mapping(address pausable => address) pauser;
        mapping(address pauser => uint256) pausableCount;
        mapping(address pauser => uint256) index;
        address[] pausers;
    }

    // =========================================================================
    // Events
    // =========================================================================

    event PauserChanged(address indexed pausable, address indexed previousPauser, address indexed pauser);

    // =========================================================================
    // Errors
    // =========================================================================

    error PausableIsZero();

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Return the pauser registered for a pausable.
    /// @param  _pausable Pausable contract address.
    function get(PauserRegistry storage _self, address _pausable) internal view returns (address) {
        return _self.pauser[_pausable];
    }

    /// @notice Return all unique pauser addresses currently registered.
    function getAll(PauserRegistry storage _self) internal view returns (address[] memory) {
        return _self.pausers;
    }

    /// @notice Return the number of unique pausers currently registered.
    function count(PauserRegistry storage _self) internal view returns (uint256) {
        return _self.pausers.length;
    }

    /// @notice Return whether an address is currently registered for at least one pausable.
    /// @param  _pauser Address to check.
    function contains(PauserRegistry storage _self, address _pauser) internal view returns (bool) {
        return _self.pausableCount[_pauser] > 0;
    }

    // =========================================================================
    // Mutative functions
    // =========================================================================

    /// @notice Register, replace, or unregister a pauser for a pausable.
    /// @param  _pausable Pausable contract address.
    /// @param  _pauser   New pauser address. Use address(0) to unregister.
    function register(PauserRegistry storage _self, address _pausable, address _pauser) internal {
        require(_pausable != address(0), PausableIsZero());

        address previousPauser = _self.pauser[_pausable];
        _self.pauser[_pausable] = _pauser;

        if (previousPauser != address(0)) _removePauser(_self, previousPauser);
        if (_pauser != address(0)) _addPauser(_self, _pauser);

        emit PauserChanged(_pausable, previousPauser, _pauser);
    }

    /// @notice Unregister the pauser for a pausable.
    /// @param  _pausable Pausable contract address.
    function unregister(PauserRegistry storage _self, address _pausable) internal {
        register(_self, _pausable, address(0));
    }

    // =========================================================================
    // Private functions
    // =========================================================================

    /// @dev Add pauser to the set if not already present.
    function _addPauser(PauserRegistry storage _self, address _pauser) private {
        if (_self.pausableCount[_pauser]++ == 0) {
            _self.pausers.push(_pauser);
            _self.index[_pauser] = _self.pausers.length;
        }
    }

    /// @dev Remove pauser from the set if no longer registered for any pausable.
    function _removePauser(PauserRegistry storage _self, address _pauser) private {
        if (--_self.pausableCount[_pauser] == 0) {
            uint256 idx = _self.index[_pauser];
            address last = _self.pausers[_self.pausers.length - 1];

            _self.pausers[idx - 1] = last;
            _self.index[last] = idx;

            _self.pausers.pop();
            delete _self.index[_pauser];
        }
    }
}
