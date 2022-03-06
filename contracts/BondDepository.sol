// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

import "./Fixidity.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IOwnable {
  function owner() external view returns (address);

  function renounceOwnership() external;
  
  function transferOwnership( address newOwner_ ) external;
}

interface ITreasury {
    function deposit( uint _amount, address _token, uint _profit ) external returns ( bool );
    function valueOf( address _token, uint _amount ) external view returns ( uint value_ );
}

interface IBondCalculator {
    function valuation( address _LP, uint _amount ) external view returns ( uint );
    function markdown( address _LP ) external view returns ( uint );
}

interface IStaking {
    function stake( uint _amount, address _recipient ) external returns ( bool );
}

interface IStakingHelper {
    function stake( uint _amount, address _recipient ) external;
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

contract gAkitaBondDepository is Ownable {

    using Fixidity for *;
    using SafeERC20 for IERC20;

    /* ======== EVENTS ======== */
    event BondCreated( uint deposit, uint indexed payout, uint indexed expires, uint indexed priceInUSD );
    event BondRedeemed( address indexed recipient, uint payout, uint remaining );
    event BondPriceChanged( uint indexed priceInUSD, uint indexed internalPrice, uint indexed debtRatio );
    event ControlVariableAdjustment( uint initialBCV, uint newBCV, uint adjustment, bool addition );


    /* ======== STATE VARIABLES ======== */

    
    IERC20 internal AKITA; // token given as payment for bond
    IERC20 internal principle; // Token used to create bond
    address public immutable treasury; // mints AKITA when receives principle
    address public immutable DAO; // receives profit share from bond

    bool public immutable isLiquidityBond; // LP and Reserve bonds are treated slightly different
    address public immutable bondCalculator; // calculates value of LP tokens

    address public staking; // to auto-stake payout
    address public stakingHelper; // to stake and claim if no staking warmup
    bool public useHelper;

    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // stores adjustment to BCV data

    mapping( address => Bond ) public bondInfo; // stores bond information for depositors

    uint public totalDebt; // total value of outstanding bonds; used for pricing
    uint public lastDecay; // reference block for debt decay



    /* ======== STRUCTS ======== */

    // Info for creating new bonds
    struct Terms {
        uint controlVariable; // scaling variable for price
        uint vestingTerm; // in blocks
        uint minimumPrice; // vs principle value
        uint maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint maxDebt; // 9 decimal debt ratio, max % total supply created as debt
    }

    // Info for bond holder
    struct Bond {
        uint payout; // AKITA remaining to be paid
        uint vesting; // Blocks left to vest
        uint lastBlock; // Last interaction
        uint pricePaid; // In DAI, for front end viewing
    }

    // Info for incremental adjustments to control variable 
    struct Adjust {
        bool add; // addition or subtraction
        uint rate; // increment
        uint target; // BCV when adjustment finished
        uint buffer; // minimum length (in blocks) between adjustments
        uint lastBlock; // block when last adjustment made
    }
    

    /* ======== INITIALIZATION ======== */

    constructor ( 
        IERC20 _AKITA,
        IERC20 _principle,
        address _treasury, 
        address _DAO, 
        address _bondCalculator
    ) {
        require( address(_AKITA) != address(0) );
        AKITA = _AKITA;
        require( address(_principle) != address(0) );
        principle = _principle;
        require( _treasury != address(0) );
        treasury = _treasury;
        require( _DAO != address(0) );
        DAO = _DAO;
        // bondCalculator should be address(0) if not LP bond
        bondCalculator = _bondCalculator;
        isLiquidityBond = ( _bondCalculator != address(0) );
    }

    /**
     *  @notice initializes bond parameters
     *  @param _controlVariable uint
     *  @param _vestingTerm uint
     *  @param _minimumPrice uint
     *  @param _maxPayout uint
     *  @param _fee uint
     *  @param _maxDebt uint
     *  @param _initialDebt uint
     */
    function initializeBondTerms( 
        uint _controlVariable, 
        uint _vestingTerm,
        uint _minimumPrice,
        uint _maxPayout,
        uint _fee,
        uint _maxDebt,
        uint _initialDebt
    ) external onlyOwner initializeNotTimeLocked {
        require( terms.controlVariable == 0, "Bonds must be initialized from 0" );
        terms = Terms ({
            controlVariable: _controlVariable,
            vestingTerm: _vestingTerm,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            fee: _fee,
            maxDebt: _maxDebt
        });
        totalDebt = _initialDebt;
        lastDecay = block.number;
        _initializeTimelock = 0;
    }

    
    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER { VESTING, PAYOUT, FEE, DEBT }
    /**
     *  @notice set parameters for new bonds
     *  @param _parameter PARAMETER
     *  @param _input uint
     */
    function setBondTerms ( PARAMETER _parameter, uint _input ) external onlyOwner setBondTermNotTimeLocked {
        if ( _parameter == PARAMETER.PAYOUT ) { // 1
            require( _input <= 1000, "Payout cannot be above 1 percent" );
            terms.maxPayout = _input;
        } else if ( _parameter == PARAMETER.FEE ) { // 2
            require( _input <= 10000, "DAO fee cannot exceed payout" );
            terms.fee = _input;
        } else if ( _parameter == PARAMETER.DEBT ) { // 3
            terms.maxDebt = _input;
        }
        _setBondTermTimelock = 0;
    }

    /**
     *  @notice set control variable adjustment
     *  @param _addition bool
     *  @param _increment uint
     *  @param _target uint
     *  @param _buffer uint
     */
    function setAdjustment ( 
        bool _addition,
        uint _increment, 
        uint _target,
        uint _buffer 
    ) external onlyOwner setAdjustmentNotTimeLocked {
        require( _increment <= Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(terms.controlVariable) , Fixidity.newFixed(25) ) , Fixidity.newFixed(1000) )), "Increment too large" );

        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastBlock: block.number
        });
        _setAdjustmentTimelock = 0;
    }

    /**
     *  @notice set contract for auto stake
     *  @param _staking address
     *  @param _helper bool
     */
    function setStaking( address _staking, bool _helper ) external onlyOwner setStakingNotTimeLocked {
        require( _staking != address(0) );
        if ( _helper ) {
            useHelper = true;
            stakingHelper = _staking;
        } else {
            useHelper = false;
            staking = _staking;
        }
        _setStakingTimelock = 0;
    }


    

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice deposit bond
     *  @param _amount uint
     *  @param _maxPrice uint
     *  @param _depositor address
     *  @return uint
     */
    function deposit( 
        uint _amount, 
        uint _maxPrice,
        address _depositor
    ) external returns ( uint ) {
        require( _depositor != address(0), "Invalid address" );

        decayDebt();
        
        uint priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint nativePrice = _bondPrice();

        require( _maxPrice >= nativePrice, "Slippage limit: more than max price" ); // slippage protection

        uint value = ITreasury( treasury ).valueOf( address(principle) , _amount );
        
        // total debt is increased
        totalDebt = totalDebt + value; 
        require( totalDebt <= terms.maxDebt, "Max capacity reached" );

        uint payout = payoutFor( value ); // payout to bonder is computed

        require( payout >= 10000000, "Bond too small" ); // must be > 0.01 AKITA ( underflow protection )
        require( payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        // profits are calculated
        uint fee = Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(payout), Fixidity.newFixed(terms.fee)) , Fixidity.newFixed(10000)));
        uint profit = Fixidity.fromFixed(Fixidity.subtract(Fixidity.subtract( Fixidity.newFixed(value) , Fixidity.newFixed(payout)) , Fixidity.newFixed(fee)));

        /**
            principle is transferred in
            approved and
            deposited into the treasury, returning (_amount - profit) AKITA
         */
        principle.safeTransferFrom( msg.sender, address(this), _amount );
        principle.approve( address( treasury ), _amount );
        ITreasury( treasury ).deposit( _amount, address(principle) , profit );
        
        if ( fee != 0 ) { // fee is transferred to dao 
            AKITA.safeTransfer( DAO, fee ); 
        }
                
        // depositor info is stored
        bondInfo[ _depositor ] = Bond({ 
            payout: bondInfo[ _depositor ].payout +  payout,
            vesting: terms.vestingTerm,
            lastBlock: block.number,
            pricePaid: priceInUSD
        });

        // indexed events are emitted
        emit BondCreated( _amount, payout, block.number + terms.vestingTerm, priceInUSD );
        emit BondPriceChanged( bondPriceInUSD(), _bondPrice(), debtRatio() );

        adjust(); // control variable is adjusted
        return payout; 
    }

    /** 
     *  @notice redeem bond for user
     *  @param _recipient address
     *  @param _stake bool
     *  @return uint
     */ 
    function redeem( address _recipient, bool _stake ) external returns ( uint ) {        
        require (_recipient == msg.sender, "Recipient must be same as Initiator");
        Bond memory info = bondInfo[ _recipient ];
        uint percentVested = percentVestedFor( _recipient ); // (blocks since last interaction / vesting term remaining)

        if ( percentVested >= 10000 ) { // if fully vested
            delete bondInfo[ _recipient ]; // delete user info
            emit BondRedeemed( _recipient, info.payout, 0 ); // emit bond data
            return stakeOrSend( _recipient, _stake, info.payout ); // pay user everything due

        } else { // if unfinished
            // calculate payout vested
            uint payout = Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(info.payout) , Fixidity.newFixed(percentVested) ) , Fixidity.newFixed(10000) ));

            // store updated deposit info
            bondInfo[ _recipient ] = Bond({
                payout: info.payout - payout,
                vesting: info.vesting - ( block.number - info.lastBlock) ,
                lastBlock: block.number,
                pricePaid: info.pricePaid
            });

            emit BondRedeemed( _recipient, payout, bondInfo[ _recipient ].payout );
            return stakeOrSend( _recipient, _stake, payout );
        }
    }



    
    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice allow user to stake payout automatically
     *  @param _stake bool
     *  @param _amount uint
     *  @return uint
     */
    function stakeOrSend( address _recipient, bool _stake, uint _amount ) internal returns ( uint ) {
        if ( !_stake ) { // if user does not want to stake
             AKITA.transfer( _recipient, _amount ); // send payout
        } else { // if user wants to stake
            if ( useHelper ) { // use if staking warmup is 0
                AKITA.approve( stakingHelper, _amount );
                IStakingHelper( stakingHelper ).stake( _amount, _recipient );
            } else {
                AKITA.approve( staking, _amount );
                IStaking( staking ).stake( _amount, _recipient );
            }
        }
        return _amount;
    }

    /**
     *  @notice makes incremental adjustment to control variable
     */
    function adjust() internal {
        uint blockCanAdjust = adjustment.lastBlock + adjustment.buffer;
        if( adjustment.rate != 0 && block.number >= blockCanAdjust ) {
            uint initial = terms.controlVariable;
            if ( adjustment.add ) {
                terms.controlVariable = terms.controlVariable + adjustment.rate;
                if ( terms.controlVariable >= adjustment.target ) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable - adjustment.rate;
                if ( terms.controlVariable <= adjustment.target ) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastBlock = block.number;
            emit ControlVariableAdjustment( initial, terms.controlVariable, adjustment.rate, adjustment.add );
        }
    }

    /**
     *  @notice reduce total debt
     */
    function decayDebt() internal {
        totalDebt = totalDebt - debtDecay();
        lastDecay = block.number;
    }




    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() public view returns ( uint ) {
        return Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(AKITA.totalSupply()) , Fixidity.newFixed(terms.maxPayout) ) , Fixidity.newFixed(100000) ));
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param _value uint
     *  @return uint
     */
     //TODO: Implement Fraction for fixed point using other library
    function payoutFor( uint _value ) public view returns ( uint ) {
        return Fixidity.fromFixed(Fixidity.divide( Fixidity.newFixedFraction( _value , bondPrice() ) , Fixidity.newFixed(1e16) ));
    }


    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() public view returns ( uint price_ ) {        
        price_ = Fixidity.fromFixed( Fixidity.divide( Fixidity.add( Fixidity.mul( Fixidity.newFixed(terms.controlVariable) , Fixidity.newFixed(debtRatio()) ) , Fixidity.newFixed(1000000000) ) , Fixidity.newFixed(1e7) ));
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;
        }
    }

    /**
     *  @notice calculate current bond price and remove floor if above
     *  @return price_ uint
     */
    function _bondPrice() internal returns ( uint price_ ) {
        price_ = Fixidity.fromFixed(Fixidity.divide( Fixidity.add( Fixidity.mul( Fixidity.newFixed(terms.controlVariable) , Fixidity.newFixed(debtRatio())) , Fixidity.newFixed(1000000000) ) , Fixidity.newFixed(1e7) ));
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;        
        } else if ( terms.minimumPrice != 0 ) {
            terms.minimumPrice = 0;
        }
    }

    /**
     *  @notice converts bond price to DAI value
     *  @return price_ uint
     */
    function bondPriceInUSD() public view returns ( uint price_ ) {
        if( isLiquidityBond ) {
            price_ = Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(bondPrice()) , Fixidity.newFixed(IBondCalculator( bondCalculator ).markdown( address(principle) ) )) , Fixidity.newFixed(100) ));
        } else {
            price_ = Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(bondPrice()) , Fixidity.newFixed(10 ** 18) ) , Fixidity.newFixed(100) ));
        }
    }


    /**
     *  @notice calculate current ratio of debt to AKITA supply
     *  @return debtRatio_ uint
     */
    function debtRatio() public view returns ( uint debtRatio_ ) {   
        uint supply = AKITA.totalSupply();
        debtRatio_ = Fixidity.fromFixed(Fixidity.divide( Fixidity.newFixedFraction( Fixidity.fromFixed(Fixidity.mul( Fixidity.newFixed(currentDebt()) , Fixidity.newFixed(1e9) )) , supply ) , Fixidity.newFixed(1e18) ));
    }

    /**
     *  @notice debt ratio in same terms for reserve or liquidity bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns ( uint ) {
        if ( isLiquidityBond ) {
            return Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(debtRatio()) , Fixidity.newFixed(IBondCalculator( bondCalculator ).markdown( address(principle) ) )) , Fixidity.newFixed(1e9) ));
        } else {
            return debtRatio();
        }
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns ( uint ) {
        return totalDebt + debtDecay();
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     * TODO: TEST IF RESULTS ARE CORRECT
     */
    function debtDecay() public view returns ( uint decay_ ) {
        uint blocksSinceLast = block.number - lastDecay;
        decay_ = Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(totalDebt) , Fixidity.newFixed(blocksSinceLast) ) , Fixidity.newFixed(terms.vestingTerm) ));
        if ( decay_ > totalDebt ) {
            decay_ = totalDebt;
        }
    }


    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param _depositor address
     *  @return percentVested_ uint
     */
    function percentVestedFor( address _depositor ) public view returns ( uint percentVested_ ) {
        Bond memory bond = bondInfo[ _depositor ];
        uint blocksSinceLast = block.number - bond.lastBlock;
        uint vesting = bond.vesting;

        if ( vesting > 0 ) {
            percentVested_ = Fixidity.fromFixed(Fixidity.divide( Fixidity.mul( Fixidity.newFixed(blocksSinceLast) , Fixidity.newFixed(10000)) , Fixidity.newFixed(vesting)));
        } else {
            percentVested_ = 0;
        }
    }

    /**
     *  @notice calculate amount of AKITA available for claim by depositor
     *  @param _depositor address
     *  @return pendingPayout_ uint
     */
    function pendingPayoutFor( address _depositor ) external view returns ( uint pendingPayout_ ) {
        uint percentVested = percentVestedFor( _depositor );
        uint payout = bondInfo[ _depositor ].payout;

        if ( percentVested >= 10000 ) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = Fixidity.fromFixed(Fixidity.divide( Fixidity.mul(Fixidity.newFixed(payout) , Fixidity.newFixed(percentVested)) , Fixidity.newFixed(10000)));
        }
    }


    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or AKITA) to the DAO
     *  @return bool
     */
    function recoverLostToken( IERC20 _token ) external returns ( bool ) {
        require( address(_token) != address(AKITA) );
        require( address(_token) != address(principle) );
        _token.safeTransfer( DAO,  _token.balanceOf( address(this) ) );
        return true;
    }

    /* ======== TIMELOCK FUNCTIONS ======== */

    uint256 private constant _TIMELOCK = 2 days;
    uint256 public _initializeTimelock = 0;
    uint256 public _setBondTermTimelock = 0;
    uint256 public _setAdjustmentTimelock = 0;
    uint256 public _setStakingTimelock = 0;

    modifier initializeNotTimeLocked() {
        require(_initializeTimelock != 0 && _initializeTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openInitializeTimeLock() external onlyOwner() {
        _initializeTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelInitializeTimeLock() external onlyOwner() {
        _initializeTimelock = 0;
    }

    modifier setBondTermNotTimeLocked() {
        require(_setBondTermTimelock != 0 && _setBondTermTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetBondTermTimeLock() external onlyOwner() {
        _setBondTermTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetBondTermTimeLock() external onlyOwner() {
        _setBondTermTimelock = 0;
    }

    modifier setAdjustmentNotTimeLocked() {
        require(_setAdjustmentTimelock != 0 && _setAdjustmentTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetAdjustmentTimeLock() external onlyOwner() {
        _setAdjustmentTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetAdjustmentTimeLock() external onlyOwner() {
        _setAdjustmentTimelock = 0;
    }

    modifier setStakingNotTimeLocked() {
        require(_setStakingTimelock != 0 && _setStakingTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetStakingTimeLock() external onlyOwner() {
        _setStakingTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetStakingTimeLock() external onlyOwner() {
        _setStakingTimelock = 0;
    }
}