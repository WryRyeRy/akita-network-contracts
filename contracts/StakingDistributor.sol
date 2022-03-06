// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity 0.8.10;

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

    function renouncePolicy() public virtual override onlyPolicy() notRenounceTimeLocked {
        emit OwnershipTransferred( _policy, address(0) );
        _policy = address(0);
        renounceTimelock = 0;
    }

    function pushPolicy( address newPolicy_ ) public virtual override onlyPolicy() notPushTimeLocked {
        require( newPolicy_ != address(0), "Ownable: new owner is the zero address");
        _newPolicy = newPolicy_;
        pushTimelock = 0;
    }

    function pullPolicy() public virtual override {
        require( msg.sender == _newPolicy );
        emit OwnershipTransferred( _policy, _newPolicy );
        _policy = _newPolicy;
    }

    // TIMELOCKS
    uint256 private constant _TIMELOCK = 2 days;
    uint256 public pushTimelock = 0;
    uint256 public renounceTimelock = 0;

    modifier notPushTimeLocked() {
        require(pushTimelock != 0 && pushTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openPushTimeLock() external onlyPolicy() {
        pushTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelPushTimeLock() external onlyPolicy() {
        pushTimelock = 0;
    }

    modifier notRenounceTimeLocked() {
        require(renounceTimelock != 0 && renounceTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openRenounceTimeLock() external onlyPolicy() {
        renounceTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelRenounceTimeLock() external onlyPolicy() {
        renounceTimelock = 0;
    }
    // END TIMELOCKS
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
            nextEpochBlock = nextEpochBlock + epochLength; // set next epoch block
            
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
                info[ _index ].rate = info[ _index ].rate + adjustment.rate; // raise rate
                if ( info[ _index ].rate >= adjustment.target ) { // if target met
                    adjustments[ _index ].rate = 0; // turn off adjustment
                }
            } else { // if rate should decrease
                info[ _index ].rate = info[ _index ].rate - adjustment.rate; // lower rate
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
                break;
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
    function addRecipient( address _recipient, uint _rewardRate ) external onlyPolicy() addRecipientNotTimeLocked {
        require( _recipient != address(0) );
        info.push( Info({
            recipient: _recipient,
            rate: _rewardRate
        }));
        addRecipientTimelock = 0;
    }

    /**
        @notice removes recipient for distributions
        @param _index uint
        @param _recipient address
     */
    function removeRecipient( uint _index, address _recipient ) external onlyPolicy() removeRecipientNotTimeLocked {
        require( _recipient == info[ _index ].recipient );
        info[ _index ].recipient = address(0);
        info[ _index ].rate = 0;
        removeRecipientTimelock = 0;
    }

    /**
        @notice set adjustment info for a collector's reward rate
        @param _index uint
        @param _add bool
        @param _rate uint
        @param _target uint
     */
    function setAdjustment( uint _index, bool _add, uint _rate, uint _target ) external onlyPolicy() setAdjustmentNotTimeLocked {
        adjustments[ _index ] = Adjust({
            add: _add,
            rate: _rate,
            target: _target
        });
        setAdjustmentTimelock = 0;
    }

     /* ======== TIMELOCK FUNCTIONS ======== */

    uint256 private constant _TIMELOCK = 2 days;
    uint256 public addRecipientTimelock = 0;
    uint256 public removeRecipientTimelock = 0;
    uint256 public setAdjustmentTimelock = 0;

    modifier addRecipientNotTimeLocked() {
        require(addRecipientTimelock != 0 && addRecipientTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openAddRecipientTimeLock() external onlyPolicy() {
        addRecipientTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelAddRecipientTimeLock() external onlyPolicy() {
        addRecipientTimelock = 0;
    }

    modifier removeRecipientNotTimeLocked() {
        require(removeRecipientTimelock != 0 && removeRecipientTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openRemoveRecipientTimeLock() external onlyPolicy() {
        removeRecipientTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelRemoveRecipientTimeLock() external onlyPolicy() {
        removeRecipientTimelock = 0;
    }

    modifier setAdjustmentNotTimeLocked() {
        require(setAdjustmentTimelock != 0 && setAdjustmentTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetAdjustmentTimeLock() external onlyPolicy() {
        setAdjustmentTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetAdjustmentTimeLock() external onlyPolicy() {
        setAdjustmentTimelock = 0;
    }
}