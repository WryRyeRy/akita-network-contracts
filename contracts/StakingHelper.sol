// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStaking {
    function stake( uint _amount, address _recipient ) external returns ( bool );
    function claim( address _recipient ) external;
}

contract StakingHelper {

    address public immutable staking;
    IERC20 public  AKITA;

    constructor ( address _staking, IERC20 _AKITA ) {
        require( _staking != address(0) );
        staking = _staking;
        require( address(_AKITA) != address(0) );
        AKITA = _AKITA;
    }

    function stake( uint _amount ) external {
        AKITA.transferFrom( msg.sender, address(this), _amount );
        AKITA.approve( staking, _amount );
        IStaking( staking ).stake( _amount, msg.sender );
        IStaking( staking ).claim( msg.sender );
    }
}