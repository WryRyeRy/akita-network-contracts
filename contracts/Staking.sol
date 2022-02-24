// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Fixidity.sol";

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

    function renounceManagement() public virtual override onlyManager() {
        emit OwnershipPushed( _owner, address(0) );
        _owner = address(0);
    }

    function pushManagement( address newOwner_ ) public virtual override onlyManager() {
        require( newOwner_ != address(0), "Ownable: new owner is the zero address");
        emit OwnershipPushed( _owner, newOwner_ );
        _newOwner = newOwner_;
    }
    
    function pullManagement() public virtual override {
        require( msg.sender == _newOwner, "Ownable: must be new owner to pull");
        emit OwnershipPulled( _owner, _newOwner );
        _owner = _newOwner;
    }
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
            deposit: Fixidity.fromFixed(Fixidity.add (Fixidity.newFixed(info.deposit) , Fixidity.newFixed(_amount) )),
            gons: Fixidity.fromFixed(Fixidity.add (Fixidity.newFixed(info.gons) , Fixidity.newFixed(IsgAKITA( address(sgAKITA) ).gonsForBalance( _amount )) )),
            expiry: Fixidity.fromFixed(Fixidity.add (Fixidity.newFixed(epoch.number) , Fixidity.newFixed(warmupPeriod) )),
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

            epoch.endBlock = Fixidity.fromFixed( Fixidity.add( Fixidity.newFixed(epoch.endBlock) , Fixidity.newFixed(epoch.length)));
            epoch.number++;
            
            if ( distributor != address(0) ) {
                IDistributor( distributor ).distribute();
            }

            uint balance = contractBalance();
            uint staked = IsgAKITA( address(sgAKITA) ).circulatingSupply();

            if( balance <= staked ) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = Fixidity.fromFixed( Fixidity.subtract( Fixidity.newFixed(balance) , Fixidity.newFixed(staked) ));
            }
        }
    }

    /**
        @notice returns contract AKITA holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns ( uint ) {
        return Fixidity.fromFixed( Fixidity.add( Fixidity.newFixed(AKITA.balanceOf( address(this) )) , Fixidity.newFixed(totalBonus) ));
    }

    /**
        @notice provide bonus to locked staking contract
        @param _amount uint
     */
    function giveLockBonus( uint _amount ) external {
        require( msg.sender == locker );
        totalBonus = Fixidity.fromFixed( Fixidity.add( Fixidity.newFixed(totalBonus) , Fixidity.newFixed( _amount ) ));

        sgAKITA.safeTransfer( locker, _amount );
    }

    /**
        @notice reclaim bonus from locked staking contract
        @param _amount uint
     */
    function returnLockBonus( uint _amount ) external {
        require( msg.sender == locker );
        totalBonus = Fixidity.fromFixed( Fixidity.subtract( Fixidity.newFixed(totalBonus) , Fixidity.newFixed( _amount ) ));
        sgAKITA.safeTransferFrom( locker, address(this), _amount );
    }

    enum CONTRACTS { DISTRIBUTOR, WARMUP, LOCKER }

    /**
        @notice sets the contract address for LP staking
        @param _contract address
     */
    function setContract( CONTRACTS _contract, address _address ) external onlyManager() {
        if( _contract == CONTRACTS.DISTRIBUTOR ) { // 0
            distributor = _address;
        } else if ( _contract == CONTRACTS.WARMUP ) { // 1
            require( warmupContract == address( 0 ), "Warmup cannot be set more than once" );
            warmupContract = _address;
        } else if ( _contract == CONTRACTS.LOCKER ) { // 2
            require( locker == address(0), "Locker cannot be set more than once" );
            locker = _address;
        }
    }
    
    /**
     * @notice set warmup period for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup( uint _warmupPeriod ) external onlyManager() {
        warmupPeriod = _warmupPeriod;
    }
}