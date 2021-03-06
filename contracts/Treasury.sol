// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IERC20Mintable {
  function mint( uint256 amount_ ) external;

  function mint( address account_, uint256 ammount_ ) external;
}
interface IAKITAERC20 {
    function burnFrom(address account_, uint256 amount_) external;
}

interface IBondCalculator {
  function valuation( address pair_, uint amount_ ) external view returns ( uint _value );
}

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
  uint256 public _transferTimelock = 0;
  uint256 public _renounceTimelock = 0;

  modifier notTransferTimeLocked() {
    require(_transferTimelock != 0 && _transferTimelock <= block.timestamp, "Timelocked");
    _;
  }

  function openTransferTimeLock() external onlyOwner() {
    _transferTimelock = block.timestamp + _TIMELOCK;
  }

  function cancelTransferTimeLock() external onlyOwner() {
    _transferTimelock = 0;
  }

  modifier notRenounceTimeLocked() {
    require(_renounceTimelock != 0 && _renounceTimelock <= block.timestamp, "Timelocked");
    _;
  }

  function openRenounceTimeLock() external onlyOwner() {
    _renounceTimelock = block.timestamp + _TIMELOCK;
  }

  function cancelRenounceTimeLock() external onlyOwner() {
    _renounceTimelock = 0;
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
    _renounceTimelock = 0;
  }

  function transferOwnership( address newOwner_ ) public virtual override onlyOwner() notTransferTimeLocked() {
    require( newOwner_ != address(0), "Ownable: new owner is the zero address");
    emit OwnershipTransferred( _owner, newOwner_ );
    _owner = newOwner_;
    _transferTimelock = 0;
  }
}


contract AkitaTreasury is Ownable {

    using SafeERC20 for IERC20;

    event Deposit( address indexed token, uint amount, uint value );
    event Withdrawal( address indexed token, uint amount, uint value );
    event CreateDebt( address indexed debtor, address indexed token, uint amount, uint value );
    event RepayDebt( address indexed debtor, address indexed token, uint amount, uint value );
    event ReservesManaged( address indexed token, uint amount );
    event ReservesUpdated( uint indexed totalReserves );
    event ReservesAudited( uint indexed totalReserves );
    event RewardsMinted( address indexed caller, address indexed recipient, uint amount );
    event ChangeQueued( MANAGING indexed managing, address queued );
    event ChangeActivated( MANAGING indexed managing, address activated, bool result );

    enum MANAGING { RESERVEDEPOSITOR, RESERVESPENDER, RESERVETOKEN, RESERVEMANAGER, LIQUIDITYDEPOSITOR, LIQUIDITYTOKEN, LIQUIDITYMANAGER, DEBTOR, REWARDMANAGER, SGAKITA }

    IERC20 public AKITA;
    uint public immutable blocksNeededForQueue;

    address[] public reserveTokens; 
    mapping( address => bool ) public isReserveToken;
    mapping( address => uint ) public reserveTokenQueue; 

    address[] public reserveDepositors; 
    mapping( address => bool ) public isReserveDepositor;
    mapping( address => uint ) public reserveDepositorQueue; 

    address[] public reserveSpenders; 
    mapping( address => bool ) public isReserveSpender;
    mapping( address => uint ) public reserveSpenderQueue; 

    address[] public liquidityTokens; 
    mapping( address => bool ) public isLiquidityToken;
    mapping( address => uint ) public LiquidityTokenQueue; 

    address[] public liquidityDepositors; 
    mapping( address => bool ) public isLiquidityDepositor;
    mapping( address => uint ) public LiquidityDepositorQueue;

    mapping( address => address ) public bondCalculator; // 

    address[] public reserveManagers; 
    mapping( address => bool ) public isReserveManager;
    mapping( address => uint ) public ReserveManagerQueue; 

    address[] public liquidityManagers; 
    mapping( address => bool ) public isLiquidityManager;
    mapping( address => uint ) public LiquidityManagerQueue; 

    address[] public debtors; 
    mapping( address => bool ) public isDebtor;
    mapping( address => uint ) public debtorQueue;
    mapping( address => mapping( address => uint )) public debtorBalance;
    mapping( address => uint256 ) public debtorTotalBalance;
    mapping( address => uint256 ) public debtorCollaterals;

    address[] public rewardManagers; 
    mapping( address => bool ) public isRewardManager;
    mapping( address => uint ) public rewardManagerQueue; 

    IERC20 public sgAKITA;
    uint public sgAKITAQueue; 
    
    uint public totalReserves; 
    uint public totalDebt;

    constructor (
        IERC20 _AKITA,
        IERC20 _WAVAX,
        IERC20 _WAVAXAKITA,
        uint _blocksNeededForQueue
    ) {
        require( address(_AKITA) != address(0) );
        AKITA = _AKITA;

        isReserveToken[ address(_WAVAX)] = true;
        reserveTokens.push( address(_WAVAX) );

       isLiquidityToken[ address(_WAVAXAKITA) ] = true;
       liquidityTokens.push( address(_WAVAXAKITA) );

        blocksNeededForQueue = _blocksNeededForQueue;
    }

    /**
        @notice allow approved address to deposit an asset for AKITA
        @param _amount uint
        @param _token address
        @param _profit uint
        @return send_ uint
     */
    function deposit( uint _amount, address _token, uint _profit ) external returns ( uint send_ ) {
        require( isReserveToken[ _token ] || isLiquidityToken[ _token ]);
        IERC20( _token ).safeTransferFrom( msg.sender, address(this), _amount );

        if ( isReserveToken[ _token ] ) {
            require( isReserveDepositor[ msg.sender ]);
        } else {
            require( isLiquidityDepositor[ msg.sender ]);
        }

        uint value = valueOf(_token, _amount);
        send_ =  value - _profit;
        IERC20Mintable( address(AKITA) ).mint( msg.sender, send_ );

        totalReserves =  totalReserves + value;
        emit ReservesUpdated( totalReserves );

        emit Deposit( _token, _amount, value );
    }

    /**
        @notice allow approved address to burn AKITA for reserves
        @param _amount uint
        @param _token address
     */
    function withdraw( uint _amount, address _token ) external {
        require( isReserveToken[ _token ] ); 
        require( isReserveSpender[ msg.sender ] );

        uint value = valueOf( _token, _amount );
        IAKITAERC20(address(AKITA)).burnFrom( msg.sender, value );

        totalReserves =  totalReserves - value;
        emit ReservesUpdated( totalReserves );

        IERC20( _token ).safeTransfer( msg.sender, _amount );

        emit Withdrawal( _token, _amount, value );
    }

    /**
        @notice allow approved address to borrow reserves
        @param _amount uint
        @param _token address
     */
    function incurDebt( uint _amount, address _token ) external {
        require( isDebtor[ msg.sender ]);
        require( isReserveToken[ _token ] );

        uint value = valueOf( _token, _amount );

        uint maximumDebt = sgAKITA.balanceOf( msg.sender );
        uint availableDebt = maximumDebt - debtorTotalBalance[ msg.sender ];

        require( value <= availableDebt);

        debtorBalance[ msg.sender ][ _token ] += value;
        debtorTotalBalance[ msg.sender ] += value;
        totalDebt += value;
  
        totalReserves =  totalReserves - value;
        emit ReservesUpdated( totalReserves );

        IERC20( _token ).safeTransfer( msg.sender, _amount );
        debtorCollaterals[ msg.sender] += _amount;
        sgAKITA.safeTransferFrom( msg.sender, address(this), _amount );
        
        emit CreateDebt( msg.sender, _token, _amount, value );
    }

    /**
        @notice allow approved address to repay borrowed reserves with reserves
        @param _amount uint
        @param _token address
     */
    function repayDebtWithReserve( uint _amount, address _token ) external {
        require( isDebtor[ msg.sender ]);
        require( isReserveToken[ _token ] );
        IERC20( _token ).safeTransferFrom( msg.sender, address(this), _amount );
        
        debtorCollaterals[ msg.sender] -= _amount;
        sgAKITA.safeTransfer( msg.sender, _amount );

        uint value = valueOf( _token, _amount );

        debtorBalance[ msg.sender ][ _token ] -= value;
        debtorTotalBalance[ msg.sender ] -= value;

        totalDebt = totalDebt - value;
        totalReserves =  totalReserves + value;
        emit ReservesUpdated( totalReserves );
        emit RepayDebt( msg.sender, _token, _amount, value );
    }

    /**
        @notice allow approved address to withdraw assets
        @param _token address
        @param _amount uint
     */
    function manage( address _token, uint _amount ) external {
        if( isLiquidityToken[ _token ] ) {
            require( isLiquidityManager[ msg.sender ] );
        } else {
            require( isReserveManager[ msg.sender ]);
        }

        uint value = valueOf(_token, _amount);
        require( value <= excessReserves());
        totalReserves -= value;
        emit ReservesUpdated( totalReserves );

        IERC20( _token ).safeTransfer( msg.sender, _amount );

        emit ReservesManaged( _token, _amount );
    }
    /**
        @notice send epoch reward to staking contract
     */
    function mintRewards( address _recipient, uint _amount ) external {
        require( isRewardManager[ msg.sender ] );
        require( _amount <= excessReserves() );
        IERC20Mintable( address(AKITA) ).mint( _recipient, _amount );
        emit RewardsMinted( msg.sender, _recipient, _amount );
    } 

    /**
        @notice returns excess reserves not backing tokens
        @return uint
     */
    function excessReserves() public view returns ( uint ) {
        return totalReserves - AKITA.totalSupply() - totalDebt;
    }
    /**
        @notice takes inventory of all tracked assets
        @notice always consolidate to recognized reserves before audit
     */
    function auditReserves() external onlyOwner NotTimeLocked(LOCKS.AUDIT) {
        uint reserves;
        for( uint i = 0; i < reserveTokens.length; i++ ) {
            reserves += valueOf( reserveTokens[ i ], IERC20( reserveTokens[ i ] ).balanceOf( address(this) ) );
        }
        for( uint i = 0; i < liquidityTokens.length; i++ ) {
            reserves +=   valueOf( liquidityTokens[ i ], IERC20( liquidityTokens[ i ] ).balanceOf( address(this) ) );
        }
        totalReserves = reserves;
        emit ReservesUpdated( reserves );
        emit ReservesAudited( reserves );
    }
    /**
        @notice returns AKITA valuation of asset
        @param _token address
        @param _amount uint
        @return value_ uint
     */
    function valueOf( address _token, uint _amount ) public view returns ( uint value_ ) {
        if ( isReserveToken[ _token ] ) {
            value_ =  _amount * ( 10 ** ERC20( address(AKITA) ).decimals() ) / ( 10 ** ERC20( _token ).decimals() );
        } else if ( isLiquidityToken[ _token ] ) {
            value_ = IBondCalculator( bondCalculator[ _token ] ).valuation( _token, _amount );
        }
    }
    /**
        @notice queue address to change boolean in mapping
        @param _managing MANAGING
        @param _address address
        @return bool
     */
   function queue( MANAGING _managing, address _address ) external onlyOwner NotTimeLocked(LOCKS.QUEUE) returns ( bool ) {
        require( _address != address(0) );
        if ( _managing == MANAGING.RESERVEDEPOSITOR ) { // 0
            reserveDepositorQueue[ _address ] = block.number + blocksNeededForQueue;
        } else if ( _managing == MANAGING.RESERVESPENDER ) { // 1
            reserveSpenderQueue[ _address ] =  block.number + blocksNeededForQueue;
        } else if ( _managing == MANAGING.RESERVETOKEN ) { // 2
             reserveTokenQueue[ _address ] =  block.number + blocksNeededForQueue;
        } else if ( _managing == MANAGING.RESERVEMANAGER ) { // 3
            ReserveManagerQueue[ _address ] = block.number + blocksNeededForQueue * 2;
        } else if ( _managing == MANAGING.LIQUIDITYDEPOSITOR ) { // 4
            LiquidityDepositorQueue[ _address ] =  block.number + blocksNeededForQueue;
        } else if ( _managing == MANAGING.LIQUIDITYTOKEN ) { // 5
            LiquidityTokenQueue[ _address ] =  block.number + blocksNeededForQueue;
        } else if ( _managing == MANAGING.LIQUIDITYMANAGER ) { // 6
            LiquidityManagerQueue[ _address ] = block.number + blocksNeededForQueue * 2;
        } else if ( _managing == MANAGING.DEBTOR ) { // 7
            debtorQueue[ _address ] =  block.number + blocksNeededForQueue;
         } else if ( _managing == MANAGING.REWARDMANAGER ) { // 8
            rewardManagerQueue[ _address ] =  block.number + blocksNeededForQueue;
        } else if ( _managing == MANAGING.SGAKITA ) { // 9
            sgAKITAQueue = block.number + blocksNeededForQueue;
        } else return false;

        emit ChangeQueued( _managing, _address );
        return true;
    }

    /**
        @notice verify queue then set boolean in mapping
        @param _managing MANAGING
        @param _address address
        @param _calculator address
        @return bool
     */
    function toggle( MANAGING _managing, address _address, address _calculator ) external onlyOwner NotTimeLocked(LOCKS.TOGGLE) returns ( bool ) {
        require( _address != address(0) );
        bool result;
        if ( _managing == MANAGING.RESERVEDEPOSITOR ) { // 0
            if ( requirements( reserveDepositorQueue, isReserveDepositor, _address ) ) {
                reserveDepositorQueue[ _address ] = 0;
                if( !listContains( reserveDepositors, _address ) ) {
                    reserveDepositors.push( _address );
                }
            }
            result = !isReserveDepositor[ _address ];
            isReserveDepositor[ _address ] = result;
            
        } else if ( _managing == MANAGING.RESERVESPENDER ) { // 1
            if ( requirements( reserveSpenderQueue, isReserveSpender, _address ) ) {
                reserveSpenderQueue[ _address ] = 0;
                if( !listContains( reserveSpenders, _address ) ) {
                    reserveSpenders.push( _address );
                }
            }
            result = !isReserveSpender[ _address ];
            isReserveSpender[ _address ] = result;

        } else if ( _managing == MANAGING.RESERVETOKEN ) { // 2
            if ( requirements( reserveTokenQueue, isReserveToken, _address ) ) {
                reserveTokenQueue[ _address ] = 0;
                if( !listContains( reserveTokens, _address ) ) {
                    reserveTokens.push( _address );
                }
            }
            result = !isReserveToken[ _address ];
            isReserveToken[ _address ] = result;

        } else if ( _managing == MANAGING.RESERVEMANAGER ) { // 3
            if ( requirements( ReserveManagerQueue, isReserveManager, _address ) ) {
                ReserveManagerQueue[ _address ] = 0;
                if( !listContains( reserveManagers, _address ) ) {
                    reserveManagers.push( _address );
                }
            }
            result = !isReserveManager[ _address ];
            isReserveManager[ _address ] = result;

        } else if ( _managing == MANAGING.LIQUIDITYDEPOSITOR ) { // 4
            if ( requirements( LiquidityDepositorQueue, isLiquidityDepositor, _address ) ) {
                LiquidityDepositorQueue[ _address ] = 0;
                if( !listContains( liquidityDepositors, _address ) ) {
                    liquidityDepositors.push( _address );
                }
            }
            result = !isLiquidityDepositor[ _address ];
            isLiquidityDepositor[ _address ] = result;

        } else if ( _managing == MANAGING.LIQUIDITYTOKEN ) { // 5
            if ( requirements( LiquidityTokenQueue, isLiquidityToken, _address ) ) {
                LiquidityTokenQueue[ _address ] = 0;
                if( !listContains( liquidityTokens, _address ) ) {
                    liquidityTokens.push( _address );
                }
            }
            result = !isLiquidityToken[ _address ];
            isLiquidityToken[ _address ] = result;
            bondCalculator[ _address ] = _calculator;

        } else if ( _managing == MANAGING.LIQUIDITYMANAGER ) { // 6
            if ( requirements( LiquidityManagerQueue, isLiquidityManager, _address ) ) {
                LiquidityManagerQueue[ _address ] = 0;
                if( !listContains( liquidityManagers, _address ) ) {
                    liquidityManagers.push( _address );
                }
            }
            result = !isLiquidityManager[ _address ];
            isLiquidityManager[ _address ] = result;

        } else if ( _managing == MANAGING.DEBTOR ) { // 7
            if ( requirements( debtorQueue, isDebtor, _address ) ) {
                debtorQueue[ _address ] = 0;
                if( !listContains( debtors, _address ) ) {
                    debtors.push( _address );
                }
            }
            result = !isDebtor[ _address ];
            isDebtor[ _address ] = result;

        } else if ( _managing == MANAGING.REWARDMANAGER ) { // 8
            if ( requirements( rewardManagerQueue, isRewardManager, _address ) ) {
                rewardManagerQueue[ _address ] = 0;
                if( !listContains( rewardManagers, _address ) ) {
                    rewardManagers.push( _address );
                }
            }
            result = !isRewardManager[ _address ];
            isRewardManager[ _address ] = result;

        } else if ( _managing == MANAGING.SGAKITA ) { // 9
            sgAKITAQueue = 0;
            sgAKITA  = IERC20(_address);
            result = true;

        } else return false;

        emit ChangeActivated( _managing, _address, result );
        return true;
    }

    /**
        @notice checks requirements and returns altered structs
        @param queue_ mapping( address => uint )
        @param status_ mapping( address => bool )
        @param _address address
        @return bool 
     */
    function requirements( 
        mapping( address => uint ) storage queue_, 
        mapping( address => bool ) storage status_, 
        address _address 
    ) internal view returns ( bool ) {
        if ( !status_[ _address ] ) {
            require( queue_[ _address ] != 0 );
            require( queue_[ _address ] <= block.number );
            return true;
        } return false;
    }

    /**
        @notice checks array to ensure against duplicate
        @param _list address[]
        @param _token address
        @return bool
     */
    function listContains( address[] storage _list, address _token ) internal view returns ( bool ) {
        for( uint i = 0; i < _list.length; i++ ) {
            if( _list[ i ] == _token ) {
                return true;
            }
        }
        return false;
    }

    /* ======== TIMELOCK FUNCTIONS ======== */

    uint256 private constant _TIMELOCK = 2 days;
    enum LOCKS {AUDIT, QUEUE, TOGGLE}
    mapping(LOCKS => uint256) _locks;

    modifier NotTimeLocked(LOCKS lock_) {
        require(_locks[lock_] != 0 &&_locks[lock_] <= block.timestamp);
        _;
        _locks[lock_] = 0;
    }

    function openLock(LOCKS lock_) external onlyOwner {
        _locks[lock_] = block.timestamp + _TIMELOCK;
    }

    function cancelLock(LOCKS lock_) external onlyOwner {
        _locks[lock_] = 0;
    }
}