// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./Fixidity.sol";

interface IOwnable {
  function owner() external view returns (address);

  function renounceOwnership() external;
  
  function transferOwnership( address newOwner_ ) external;
}

contract Ownable is IOwnable {
    
  address internal _owner;

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  // TIMELOCKS
  uint256 private constant _TIMELOCK = 2 days;
  uint256 public transferTimelock = 0;
  uint256 public renounceTimelock = 0;

  modifier notTransferTimeLocked() {
    require(transferTimelock != 0 && transferTimelock <= block.timestamp, "Timelocked");
    _;
  }

  function openTransferTimeLock() external onlyOwner() {
    transferTimelock = block.timestamp + _TIMELOCK;
  }

  function cancelTransferTimeLock() external onlyOwner() {
    transferTimelock = 0;
  }

  modifier notRenounceTimeLocked() {
    require(renounceTimelock != 0 && renounceTimelock <= block.timestamp, "Timelocked");
    _;
  }

  function openRenounceTimeLock() external onlyOwner() {
    renounceTimelock = block.timestamp + _TIMELOCK;
  }

  function cancelRenounceTimeLock() external onlyOwner() {
    renounceTimelock = 0;
  }
  // END TIMELOCKS

  constructor () {
    _owner = msg.sender;
    emit OwnershipTransferred( address(0), _owner );
  }

  function owner() public view override returns (address) {
    return _owner;
  }

  modifier onlyOwner() {
    require( _owner == msg.sender, "Ownable: caller is not the owner" );
    _;
  }

  function renounceOwnership() public virtual override onlyOwner() notRenounceTimeLocked() {
    emit OwnershipTransferred( _owner, address(0) );
    _owner = address(0);
    renounceTimelock = 0;
  }

  function transferOwnership( address newOwner_ ) public virtual override onlyOwner() notTransferTimeLocked() {
    require( newOwner_ != address(0), "Ownable: new owner is the zero address");
    emit OwnershipTransferred( _owner, newOwner_ );
    _owner = newOwner_;
    transferTimelock = 0;
  }
}

contract sgAkita is ERC20, Ownable {

    modifier onlyStakingContract() {
        require( msg.sender == stakingContract );
        _;
    }

    uint256 private constant _TIMELOCK = 2 days;
    uint256 public setIndexTimelock = 0;
    uint256 public rebaseTimelock = 0;

    address public stakingContract;
    address public initializer;

    event LogSupply(uint256 indexed epoch, uint256 timestamp, uint256 totalSupply );
    event LogRebase( uint256 indexed epoch, uint256 rebase, uint256 index );
    event LogStakingContractUpdated( address stakingContract );

    struct Rebase {
        uint epoch;
        uint rebase; // 18 decimals
        uint totalStakedBefore;
        uint totalStakedAfter;
        uint amountRebased;
        uint index;
        uint blockNumberOccured;
    }
    Rebase[] public rebases;

    uint public INDEX;

    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 5000000 * 10**9;
    uint private total_token_supply;
    // TOTAL_GONS is a multiple of INITIAL_FRAGMENTS_SUPPLY so that _gonsPerFragment is an integer.
    // Use the highest value that fits in a uint256 for max granularity.
    uint256 private constant TOTAL_GONS = MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);

    // MAX_SUPPLY = maximum integer < (sqrt(4*TOTAL_GONS + 1) - 1) / 2
    uint256 private constant MAX_SUPPLY = ~uint128(0);  // (2^128) - 1

    uint256 private _gonsPerFragment;
    mapping(address => uint256) private _gonBalances;

    mapping ( address => mapping ( address => uint256 ) ) private _allowedValue;

    constructor() ERC20("Staked gAkita", "sgAKITA")  {
        initializer = msg.sender;
        total_token_supply = INITIAL_FRAGMENTS_SUPPLY;
        _mint(msg.sender, total_token_supply);
        _gonsPerFragment = Fixidity.fromFixed( Fixidity.divide( Fixidity.newFixed(TOTAL_GONS) , Fixidity.newFixed(total_token_supply)));
    }

    function initialize( address stakingContract_ ) external returns ( bool ) {
        require( msg.sender == initializer );
        require( stakingContract_ != address(0) );
        stakingContract = stakingContract_;
        _gonBalances[ stakingContract ] = TOTAL_GONS;

        emit Transfer( address(0x0), stakingContract, total_token_supply );
        emit LogStakingContractUpdated( stakingContract_ );
        
        initializer = address(0);
        return true;
    }

    function setIndex( uint _INDEX ) external onlyOwner setIndexNotTimeLocked returns ( bool ) {
        require( INDEX == 0 );
        INDEX = gonsForBalance( _INDEX );
        setIndexTimelock = 0;
        return true;
    }

    /**
        @notice increases g supply to increase staking balances relative to profit_
        @param profit_ uint256
        @return uint256
     */
    function rebase( uint256 profit_, uint epoch_ ) public onlyStakingContract() rebaseNotTimeLocked returns ( uint256 ) {
        uint256 rebaseAmount;
        uint256 circulatingSupply_ = circulatingSupply();

        if ( profit_ == 0 ) {
            emit LogSupply( epoch_, block.timestamp, total_token_supply );
            emit LogRebase( epoch_, 0, index() );
            return total_token_supply;
        } else if ( circulatingSupply_ > 0 ){
            rebaseAmount = Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(profit_) , Fixidity.newFixed(total_token_supply) ) , Fixidity.newFixed(circulatingSupply_) ));
        } else {
            rebaseAmount = profit_;
        }

        total_token_supply = total_token_supply + rebaseAmount;

        if ( total_token_supply > MAX_SUPPLY ) {
            total_token_supply = MAX_SUPPLY;
        }

        _gonsPerFragment = Fixidity.fromFixed( Fixidity.divide( Fixidity.newFixed(TOTAL_GONS) , Fixidity.newFixed(total_token_supply) ));

        _storeRebase( circulatingSupply_, profit_, epoch_, rebaseAmount );

        rebaseTimelock = 0;
        return total_token_supply;
    }

    /**
        @notice emits event with data about rebase
        @param previousCirculating_ uint
        @param rebaseAmount_ uint
        @param epoch_ uint
        @return bool
     */
    function _storeRebase( uint previousCirculating_, uint profit_, uint epoch_, uint rebaseAmount_ ) internal returns ( bool ) {
        uint rebasePercent = previousCirculating_ == 0 ? 0 : Fixidity.fromFixed( Fixidity.divide( Fixidity.mul( Fixidity.newFixed(profit_) , Fixidity.newFixed(1e18) ) , Fixidity.newFixed(previousCirculating_)) );

        rebases.push( Rebase ( {
            epoch: epoch_,
            rebase: rebasePercent, // 18 decimals
            totalStakedBefore: previousCirculating_,
            totalStakedAfter: circulatingSupply(),
            amountRebased: rebaseAmount_,
            index: index(),
            blockNumberOccured: block.number
        }));
        
        emit LogSupply( epoch_, block.timestamp, total_token_supply );
        emit LogRebase( epoch_, rebasePercent, index() );

        return true;
    }

    function balanceOf( address who ) public view override returns ( uint256 ) {
        return Fixidity.fromFixed( Fixidity.divide( Fixidity.newFixed(_gonBalances[ who ]) , Fixidity.newFixed(_gonsPerFragment) ));
    }

    function gonsForBalance( uint amount ) public view returns ( uint ) {
        return amount * _gonsPerFragment;
    }

    function balanceForGons( uint gons ) public view returns ( uint ) {
        return Fixidity.fromFixed( Fixidity.divide( Fixidity.newFixed(gons) , Fixidity.newFixed(_gonsPerFragment) ));
    }

    // Staking contract holds excess sgAKITA
    function circulatingSupply() public view returns ( uint ) {
        return total_token_supply - balanceOf( stakingContract );
    }

    function index() public view returns ( uint ) {
        return balanceForGons( INDEX );
    }

    function transfer( address to, uint256 value ) public override returns (bool) {
        uint256 gonValue = value * _gonsPerFragment;
        _gonBalances[ msg.sender ] = _gonBalances[ msg.sender ] - gonValue;
        _gonBalances[ to ] = _gonBalances[ to ] + gonValue;
        emit Transfer( msg.sender, to, value );
        return true;
    }

    function allowance( address owner_, address spender ) public view override returns ( uint256 ) {
        return _allowedValue[ owner_ ][ spender ];
    }

    function transferFrom( address from, address to, uint256 value ) public override returns ( bool ) {
       _allowedValue[ from ][ msg.sender ] = _allowedValue[ from ][ msg.sender ] - value;
       emit Approval( from, msg.sender,  _allowedValue[ from ][ msg.sender ] );

        uint256 gonValue = gonsForBalance( value );
        _gonBalances[ from ] = _gonBalances[from] - gonValue;
        _gonBalances[ to ] = _gonBalances[ to ] + gonValue;
        emit Transfer( from, to, value );

        return true;
    }

    function approve( address spender, uint256 value ) public override returns (bool) {
         _allowedValue[ msg.sender ][ spender ] = value;
         emit Approval( msg.sender, spender, value );
         return true;
    }

    function increaseAllowance( address spender, uint256 addedValue ) public override returns (bool) {
        _allowedValue[ msg.sender ][ spender ] = _allowedValue[ msg.sender ][ spender ] + addedValue;
        emit Approval( msg.sender, spender, _allowedValue[ msg.sender ][ spender ] );
        return true;
    }

    function decreaseAllowance( address spender, uint256 subtractedValue ) public override returns (bool) {
        uint256 oldValue = _allowedValue[ msg.sender ][ spender ];
        if (subtractedValue >= oldValue) {
            _allowedValue[ msg.sender ][ spender ] = 0;
        } else {
            _allowedValue[ msg.sender ][ spender ] = oldValue - subtractedValue;
        }
        emit Approval( msg.sender, spender, _allowedValue[ msg.sender ][ spender ] );
        return true;
    }

    /* ======== TIMELOCK FUNCTIONS ======== */

    modifier setIndexNotTimeLocked() {
        require(setIndexTimelock != 0 && setIndexTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetIndexTimeLock() external onlyOwner() {
        setIndexTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetIndexTimeLock() external onlyOwner() {
        setIndexTimelock = 0;
    }

    modifier rebaseNotTimeLocked() {
        require(rebaseTimelock != 0 && rebaseTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openRebaseTimeLock() external onlyStakingContract() {
        rebaseTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelRebaseTimeLock() external onlyStakingContract() {
        rebaseTimelock = 0;
    }
}