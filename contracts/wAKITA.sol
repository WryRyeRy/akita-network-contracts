// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./Fixidity.sol";

interface IStaking {
    function stake( uint _amount, address _recipient ) external returns ( bool );

    function unstake( uint _amount, address _recipient ) external returns ( bool );

    function index() external view returns ( uint );
}

contract wAKITA is ERC20 {


    address public immutable staking;
    IERC20 public  AKITA;
    IERC20 public sgAKITA;

    constructor( address _staking, IERC20 _AKITA, IERC20 _sgAKITA ) ERC20( 'Wrapped sgAKITA', 'wsgAKITA' ) {
        require( _staking != address(0) );
        staking = _staking;
        require( address(_AKITA) != address(0) );
        AKITA = _AKITA;
        require( address(_sgAKITA) != address(0) );
        sgAKITA = _sgAKITA;
    }

        /**
        @notice stakes AKITA and wraps sgAKITA
        @param _amount uint
        @return uint
     */
    function wrapFromAKITA( uint _amount ) external returns ( uint ) {
        AKITA.transferFrom( msg.sender, address(this), _amount );

        AKITA.approve( staking, _amount ); // stake AKITA for sgAKITA
        IStaking( staking ).stake( _amount, address(this) );

        uint value = wAKITAValue( _amount );
        _mint( msg.sender, value );
        return value;
    }

    /**
        @notice unwrap sgAKITA and unstake AKITA
        @param _amount uint
        @return uint
     */
    function unwrapToAKITA( uint _amount ) external returns ( uint ) {
        _burn( msg.sender, _amount );
        
        uint value = sgAKITAValue( _amount );
        sgAKITA.approve( staking, value ); // unstake sgAKITA for AKITA
        IStaking( staking ).unstake( value, address(this) );

        AKITA.transfer( msg.sender, value );
        return value;
    }

    /**
        @notice wrap sgAKITA
        @param _amount uint
        @return uint
     */
    function wrapFromsgAKITA( uint _amount ) external returns ( uint ) {
        sgAKITA.transferFrom( msg.sender, address(this), _amount );
        
        uint value = wAKITAValue( _amount );
        _mint( msg.sender, value );
        return value;
    }

    /**
        @notice unwrap sgAKITA
        @param _amount uint
        @return uint
     */
    function unwrapTosgAKITA( uint _amount ) external returns ( uint ) {
        _burn( msg.sender, _amount );

        uint value = sgAKITAValue( _amount );
        sgAKITA.transfer( msg.sender, value );
        return value;
    }

    /**
        @notice converts wAKITA amount to sgAKITA
        @param _amount uint
        @return uint
     */
    function sgAKITAValue( uint _amount ) public view returns ( uint ) {
        return Fixidity.fromFixed(Fixidity.divide(
            Fixidity.mul( 
                Fixidity.newFixed(IStaking( staking ).index()), Fixidity.newFixed(_amount)), 
                Fixidity.newFixed(10 ** decimals())));
    }

    /**
        @notice converts sgAKITA amount to wAKITA
        @param _amount uint
        @return uint
     */
    function wAKITAValue( uint _amount ) public view returns ( uint ) {
        return Fixidity.fromFixed(Fixidity.divide(
            Fixidity.mul( 
                Fixidity.newFixed(_amount), Fixidity.newFixed(10 ** decimals())), 
                Fixidity.newFixed(IStaking( staking ).index())));
    }

}