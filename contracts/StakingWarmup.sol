// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakingWarmup {

    using SafeERC20 for IERC20;

    address public immutable staking;
    IERC20 public sgAKITA;

    constructor ( address _staking, IERC20 _sgAKITA ) {
        require( _staking != address(0) );
        staking = _staking;
        require( address(_sgAKITA) != address(0) );
        sgAKITA = _sgAKITA;
    }

    function retrieve( address _staker, uint _amount ) external {
        require( msg.sender == staking );
        sgAKITA.safeTransfer( _staker, _amount );
    }
}