// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

interface IOwnable {
  function policy() external view returns (address);

  function renounceManagement() external;
  
  function pushManagement( address newOwner_ ) external;
  
  function pullManagement() external;
}

contract Ownable is IOwnable {

    address internal _owner;
    address internal _newOwner;

    event OwnershipPushed(address indexed previousOwner, address indexed newOwner);
    event OwnershipPulled(address indexed previousOwner, address indexed newOwner);

    // TIMELOCKS
    uint256 private constant _TIMELOCK = 2 days;
    uint256 public _pushTimelock = 0;
    uint256 public _renounceTimelock = 0;

    modifier notPushTimeLocked() {
        require(_pushTimelock != 0 && _pushTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openPushTimeLock() external onlyPolicy() {
        _pushTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelPushTimeLock() external onlyPolicy() {
        _pushTimelock = 0;
    }

    modifier notRenounceTimeLocked() {
        require(_renounceTimelock != 0 && _renounceTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openRenounceTimeLock() external onlyPolicy() {
        _renounceTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelRenounceTimeLock() external onlyPolicy() {
        _renounceTimelock = 0;
    }
    // END TIMELOCKS

    constructor () {
        _owner = msg.sender;
        emit OwnershipPushed( address(0), _owner );
    }

    function policy() public view override returns (address) {
        return _owner;
    }

    modifier onlyPolicy() {
        require( _owner == msg.sender, "Ownable: caller is not the owner" );
        _;
    }

    function renounceManagement() public virtual override onlyPolicy() notRenounceTimeLocked {
        emit OwnershipPushed( _owner, address(0) );
        _owner = address(0);
        _renounceTimelock = 0;
    }

    function pushManagement( address newOwner_ ) public virtual override onlyPolicy() notPushTimeLocked {
        require( newOwner_ != address(0), "Ownable: new owner is the zero address");
        emit OwnershipPushed( _owner, newOwner_ );
        _newOwner = newOwner_;
        _pushTimelock = 0;
    }
    
    function pullManagement() public virtual override {
        require( msg.sender == _newOwner, "Ownable: must be new owner to pull");
        emit OwnershipPulled( _owner, _newOwner );
        _owner = _newOwner;
    }
}

interface IBond {
    function redeem( address _recipient, bool _stake ) external returns ( uint );
    function pendingPayoutFor( address _depositor ) external view returns ( uint pendingPayout_ );
}

contract RedeemHelper is Ownable {

    uint256 private constant _TIMELOCK = 2 days;
    uint256 public _addBondTimelock = 0;
    uint256 public _removeBondTimelock = 0;

    address[] public bonds;

    function redeemAll( address _recipient, bool _stake ) external {
        for( uint i = 0; i < bonds.length; i++ ) {
            if ( bonds[i] != address(0) ) {
                if ( IBond( bonds[i] ).pendingPayoutFor( _recipient ) > 0 ) {
                    IBond( bonds[i] ).redeem( _recipient, _stake );
                }
            }
        }
    }

    function addBondContract( address _bond ) external onlyPolicy() addBondNotTimeLocked {
        require( _bond != address(0) );
        bonds.push( _bond );
        _addBondTimelock = 0;
    }

    function removeBondContract( uint _index ) external onlyPolicy() removeBondNotTimeLocked {
        bonds[ _index ] = address(0);
        _removeBondTimelock = 0;
    }

    modifier addBondNotTimeLocked() {
        require(_addBondTimelock != 0 && _addBondTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openAddBondTimeLock() external onlyPolicy() {
        _addBondTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelAddBondTimeLock() external onlyPolicy() {
        _addBondTimelock = 0;
    }

    modifier removeBondNotTimeLocked() {
        require(_removeBondTimelock != 0 && _removeBondTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openRemoveBondTimeLock() external onlyPolicy() {
        _removeBondTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelRemoveBondTimeLock() external onlyPolicy() {
        _removeBondTimelock = 0;
    }
}