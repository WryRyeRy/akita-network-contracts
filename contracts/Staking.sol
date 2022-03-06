// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOwnable {
  function manager() external view returns (address);

  function renounceManagement() external;
  
  function pushManagement( address newOwner_ ) external;
  
  function pullManagement() external;
}

contract Ownable is IOwnable {
    
    address internal _owner;
    address internal _newOwner;

    event OwnershipPushed(address indexed previousOwner, address indexed newOwner);
    event OwnershipPulled(address indexed previousOwner, address indexed newOwner);

    constructor () {
        _owner = msg.sender;
        emit OwnershipPushed( address(0), _owner );
    }

    function manager() public view override returns (address) {
        return _owner;
    }

    modifier onlyManager() {
        require( _owner == msg.sender, "Ownable: caller is not the owner" );
        _;
    }

    function renounceManagement() public virtual override onlyManager() notRenounceTimeLocked {
        emit OwnershipPushed( _owner, address(0) );
        _owner = address(0);
        renounceTimelock = 0;
    }

    function pushManagement( address newOwner_ ) public virtual override onlyManager() notPushTimeLocked {
        require( newOwner_ != address(0), "Ownable: new owner is the zero address");
        emit OwnershipPushed( _owner, newOwner_ );
        _newOwner = newOwner_;
        pushTimelock = 0;
    }
    
    function pullManagement() public virtual override {
        require( msg.sender == _newOwner, "Ownable: must be new owner to pull");
        emit OwnershipPulled( _owner, _newOwner );
        _owner = _newOwner;
    }

    // TIMELOCKS
    uint256 private constant _TIMELOCK = 2 days;
    uint256 public pushTimelock = 0;
    uint256 public renounceTimelock = 0;

    modifier notPushTimeLocked() {
        require(pushTimelock != 0 && pushTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openPushTimeLock() external onlyManager() {
        pushTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelPushTimeLock() external onlyManager() {
        pushTimelock = 0;
    }

    modifier notRenounceTimeLocked() {
        require(renounceTimelock != 0 && renounceTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openRenounceTimeLock() external onlyManager() {
        renounceTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelRenounceTimeLock() external onlyManager() {
        renounceTimelock = 0;
    }
    // END TIMELOCKS
}

interface IsgAKITA {
    function rebase( uint256 AKITAProfit_, uint epoch_) external returns (uint256);

    function circulatingSupply() external view returns (uint256);

    function balanceOf(address who) external view returns (uint256);

    function gonsForBalance( uint amount ) external view returns ( uint );

    function balanceForGons( uint gons ) external view returns ( uint );
    
    function index() external view returns ( uint );
}

interface IWarmup {
    function retrieve( address staker_, uint amount_ ) external;
}

interface IDistributor {
    function distribute() external returns ( bool );
}

contract AkitaStaking is Ownable {

    IERC20 public immutable AKITA;
    IERC20 public immutable sgAKITA;

    using SafeERC20 for IERC20;

    struct Epoch {
        uint length;
        uint number;
        uint endBlock;
        uint distribute;
    }
    Epoch public epoch;

    address public distributor;
    
    address public locker;
    uint public totalBonus;
    
    address public warmupContract;
    uint public warmupPeriod;
    
    

    constructor ( 
        IERC20 _AKITA, 
        IERC20 _sgAKITA, 
        uint _epochLength,
        uint _firstEpochNumber,
        uint _firstEpochBlock
    ) {
        require( address(_AKITA) != address(0) );
        AKITA = _AKITA;
        require( address(_sgAKITA) != address(0) );
        sgAKITA = _sgAKITA;
        
        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endBlock: _firstEpochBlock,
            distribute: 0
        });
    }

    struct Claim {
        uint deposit;
        uint gons;
        uint expiry;
        bool lock; // prevents malicious delays
    }
    mapping( address => Claim ) public warmupInfo;

    /**
        @notice stake AKITA to enter warmup
        @param _amount uint
        @return bool
     */
    function stake( uint _amount, address _recipient ) external returns ( bool ) {
        rebase();
        
        AKITA.safeTransferFrom( msg.sender, address(this), _amount );

        Claim memory info = warmupInfo[ _recipient ];
        require( !info.lock, "Deposits for account are locked" );

        warmupInfo[ _recipient ] = Claim ({
            deposit: info.deposit + _amount,
            gons: info.gons + IsgAKITA( address(sgAKITA) ).gonsForBalance( _amount ), 
            expiry: epoch.number + warmupPeriod,
            lock: false
        });
        
        sgAKITA.safeTransfer( warmupContract, _amount );
        return true;
    }

    /**
        @notice retrieve sgAKITA from warmup
        @param _recipient address
     */
    function claim ( address _recipient ) public {
        Claim memory info = warmupInfo[ _recipient ];
        if ( epoch.number >= info.expiry && info.expiry != 0 ) {
            delete warmupInfo[ _recipient ];
            IWarmup( warmupContract ).retrieve( _recipient, IsgAKITA( address(sgAKITA) ).balanceForGons( info.gons ) );
        }
    }

    /**
        @notice forfeit sgAKITA in warmup and retrieve AKITA
     */
    function forfeit() external {
        Claim memory info = warmupInfo[ msg.sender ];
        delete warmupInfo[ msg.sender ];

        IWarmup( warmupContract ).retrieve( address(this), IsgAKITA( address(sgAKITA) ).balanceForGons( info.gons ) );
        AKITA.safeTransfer( msg.sender, info.deposit );
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        warmupInfo[ msg.sender ].lock = !warmupInfo[ msg.sender ].lock;
    }

    /**
        @notice redeem sgAKITA for AKITA
        @param _amount uint
        @param _trigger bool
     */
    function unstake( uint _amount, bool _trigger ) external {
        if ( _trigger ) {
            rebase();
        }
        sgAKITA.safeTransferFrom( msg.sender, address(this), _amount );
        AKITA.safeTransfer( msg.sender, _amount );
    }

    /**
        @notice returns the sgAKITA index, which tracks rebase growth
        @return uint
     */
    function index() public view returns ( uint ) {
        return IsgAKITA( address(sgAKITA) ).index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if( epoch.endBlock <= block.number ) {

            IsgAKITA( address(sgAKITA) ).rebase( epoch.distribute, epoch.number );

            epoch.endBlock = epoch.endBlock + epoch.length;
            epoch.number++;
            
            if ( distributor != address(0) ) {
                IDistributor( distributor ).distribute();
            }

            uint balance = contractBalance();
            uint staked = IsgAKITA( address(sgAKITA) ).circulatingSupply();

            if( balance <= staked ) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance - staked;
            }
        }
    }

    /**
        @notice returns contract AKITA holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns ( uint ) {
        return AKITA.balanceOf( address(this) ) + totalBonus; 
    }

    /**
        @notice provide bonus to locked staking contract
        @param _amount uint
     */
    function giveLockBonus( uint _amount ) external giveLockBonusNotTimeLocked {
        require( msg.sender == locker );
        totalBonus = totalBonus - _amount;

        sgAKITA.safeTransfer( locker, _amount );
        giveLockBonusTimelock = 0;
    }

    /**
        @notice reclaim bonus from locked staking contract
        @param _amount uint
     */
    function returnLockBonus( uint _amount ) external returnLockBonusNotTimeLocked {
        require( msg.sender == locker );
        totalBonus = totalBonus - _amount;
        sgAKITA.safeTransferFrom( locker, address(this), _amount );
        returnLockBonusTimelock = 0;
    }

    enum CONTRACTS { DISTRIBUTOR, WARMUP, LOCKER }

    /**
        @notice sets the contract address for LP staking
        @param _contract address
     */
    function setContract( CONTRACTS _contract, address _address ) external onlyManager() setContractNotTimeLocked {
        if( _contract == CONTRACTS.DISTRIBUTOR ) { // 0
            distributor = _address;
        } else if ( _contract == CONTRACTS.WARMUP ) { // 1
            require( warmupContract == address( 0 ), "Warmup cannot be set more than once" );
            warmupContract = _address;
        } else if ( _contract == CONTRACTS.LOCKER ) { // 2
            require( locker == address(0), "Locker cannot be set more than once" );
            locker = _address;
        }
        setContractTimelock = 0;
    }
    
    /**
     * @notice set warmup period for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup( uint _warmupPeriod ) external onlyManager() setWarmuptNotTimeLocked {
        warmupPeriod = _warmupPeriod;
        setWarmupTimelock = 0;
    }

    /* ======== TIMELOCK FUNCTIONS ======== */

    uint256 private constant _TIMELOCK = 2 days;
    uint256 public setContractTimelock = 0;
    uint256 public setWarmupTimelock = 0;
    uint256 public giveLockBonusTimelock = 0;
    uint256 public returnLockBonusTimelock = 0;

    modifier setContractNotTimeLocked() {
        require(setContractTimelock != 0 && setContractTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetContractTimeLock() external onlyManager() {
        setContractTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetContractTimeLock() external onlyManager() {
        setContractTimelock = 0;
    }

    modifier setWarmuptNotTimeLocked() {
        require(setWarmupTimelock != 0 && setWarmupTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetWarmupTimeLock() external onlyManager() {
        setWarmupTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetWarmupTimeLock() external onlyManager() {
        setWarmupTimelock = 0;
    }

    modifier giveLockBonusNotTimeLocked() {
        require(giveLockBonusTimelock != 0 && giveLockBonusTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openGiveLockBonusTimeLock() external onlyManager() {
        giveLockBonusTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelGiveLockBonusTimeLock() external onlyManager() {
        giveLockBonusTimelock = 0;
    }

    modifier returnLockBonusNotTimeLocked() {
        require(returnLockBonusTimelock != 0 && returnLockBonusTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openReturnLockBonusTimeLock() external onlyManager() {
        returnLockBonusTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelReturnLockBonusTimeLock() external onlyManager() {
        returnLockBonusTimelock = 0;
    }
}