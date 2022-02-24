// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity 0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Fixidity.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


interface IPolicy {

    function policy() external view returns (address);

    function renouncePolicy() external;
  
    function pushPolicy( address newPolicy_ ) external;

    function pullPolicy() external;
}

contract Policy is IPolicy {
    
    address internal _policy;
    address internal _newPolicy;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor () {
        _policy = msg.sender;
        emit OwnershipTransferred( address(0), _policy );
    }

    function policy() public view override returns (address) {
        return _policy;
    }

    modifier onlyPolicy() {
        require( _policy == msg.sender, "Ownable: caller is not the owner" );
        _;
    }

    function renouncePolicy() public virtual override onlyPolicy() {
        emit OwnershipTransferred( _policy, address(0) );
        _policy = address(0);
    }

    function pushPolicy( address newPolicy_ ) public virtual override onlyPolicy() {
        require( newPolicy_ != address(0), "Ownable: new owner is the zero address");
        _newPolicy = newPolicy_;
    }

    function pullPolicy() public virtual override {
        require( msg.sender == _newPolicy );
        emit OwnershipTransferred( _policy, _newPolicy );
        _policy = _newPolicy;
    }
}

interface ITreasury {
    function mintRewards( address _recipient, uint _amount ) external;
}

contract Distributor is Policy {
    
    /* ====== VARIABLES ====== */

    IERC20 public  AKITA;
    address public immutable treasury;
    
    uint public immutable epochLength;
    uint public nextEpochBlock;
    
    mapping( uint => Adjust ) public adjustments;
    
    
    /* ====== STRUCTS ====== */
        
    struct Info {
        uint rate; // in ten-thousandths ( 5000 = 0.5% )
        address recipient;
    }
    Info[] public info;
    
    struct Adjust {
        bool add;
        uint rate;
        uint target;
    }
    
    
    /* ====== CONSTRUCTOR ====== */

    constructor( address _treasury, IERC20 _akita, uint _epochLength, uint _nextEpochBlock ) {        
        require( _treasury != address(0) );
        treasury = _treasury;
        require( address(_akita) != address(0) );
        AKITA = _akita;
        epochLength = _epochLength;
        nextEpochBlock = _nextEpochBlock;
    }
    
    
    
    /* ====== PUBLIC FUNCTIONS ====== */
    
    /**
        @notice send epoch reward to staking contract
     */
    function distribute() external returns ( bool ) {
        if ( nextEpochBlock <= block.number ) {
            nextEpochBlock = Fixidity.fromFixed( Fixidity.add( Fixidity.newFixed(nextEpochBlock) , Fixidity.newFixed(epochLength))); // set next epoch block
            
            // distribute rewards to each recipient
            for ( uint i = 0; i < info.length; i++ ) {
                if ( info[ i ].rate > 0 ) {
                    ITreasury( treasury ).mintRewards( // mint and send from treasury
                        info[ i ].recipient, 
                        nextRewardAt( info[ i ].rate ) 
                    );
                    adjust( i ); // check for adjustment
                }
            }
            return true;
        } else { 
            return false; 
        }
    }
    
    
    
    /* ====== INTERNAL FUNCTIONS ====== */

    /**
        @notice increment reward rate for collector
     */
    function adjust( uint _index ) internal {
        Adjust memory adjustment = adjustments[ _index ];
        if ( adjustment.rate != 0 ) {
            if ( adjustment.add ) { // if rate should increase
                info[ _index ].rate = Fixidity.fromFixed( Fixidity.add( Fixidity.newFixed(info[ _index ].rate) , Fixidity.newFixed(adjustment.rate))); // raise rate
                if ( info[ _index ].rate >= adjustment.target ) { // if target met
                    adjustments[ _index ].rate = 0; // turn off adjustment
                }
            } else { // if rate should decrease
                info[ _index ].rate = Fixidity.fromFixed( Fixidity.subtract( Fixidity.newFixed(info[ _index ].rate) , Fixidity.newFixed(adjustment.rate))); // lower rate
                if ( info[ _index ].rate <= adjustment.target ) { // if target met
                    adjustments[ _index ].rate = 0; // turn off adjustment
                }
            }
        }
    }
    
    
    
    /* ====== VIEW FUNCTIONS ====== */

    /**
        @notice view function for next reward at given rate
        @param _rate uint
        @return uint
     */
    function nextRewardAt( uint _rate ) public view returns ( uint ) {
        return Fixidity.fromFixed( Fixidity.divide( Fixidity.mul( Fixidity.newFixed(AKITA.totalSupply()) , Fixidity.newFixed(_rate)) , Fixidity.newFixed(1000000))); 
    }

    /**
        @notice view function for next reward for specified address
        @param _recipient address
        @return uint
     */
    function nextRewardFor( address _recipient ) public view returns ( uint ) {
        uint reward;
        for ( uint i = 0; i < info.length; i++ ) {
            if ( info[ i ].recipient == _recipient ) {
                reward = nextRewardAt( info[ i ].rate );
            }
        }
        return reward;
    }
    
    
    
    /* ====== POLICY FUNCTIONS ====== */

    /**
        @notice adds recipient for distributions
        @param _recipient address
        @param _rewardRate uint
     */
    function addRecipient( address _recipient, uint _rewardRate ) external onlyPolicy() {
        require( _recipient != address(0) );
        info.push( Info({
            recipient: _recipient,
            rate: _rewardRate
        }));
    }

    /**
        @notice removes recipient for distributions
        @param _index uint
        @param _recipient address
     */
    function removeRecipient( uint _index, address _recipient ) external onlyPolicy() {
        require( _recipient == info[ _index ].recipient );
        info[ _index ].recipient = address(0);
        info[ _index ].rate = 0;
    }

    /**
        @notice set adjustment info for a collector's reward rate
        @param _index uint
        @param _add bool
        @param _rate uint
        @param _target uint
     */
    function setAdjustment( uint _index, bool _add, uint _rate, uint _target ) external onlyPolicy() {
        adjustments[ _index ] = Adjust({
            add: _add,
            rate: _rate,
            target: _target
        });
    }
}