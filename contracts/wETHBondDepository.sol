// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

import "./Fixidity.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
        renounceTimelock = 0;
    }

    function pushManagement( address newOwner_ ) public virtual override onlyPolicy() notPushTimeLocked {
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

interface AggregatorV3Interface {

  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);

  // getRoundData and latestRoundData should both raise "No data present"
  // if they do not have data to report, instead of returning unset values
  // which could be misinterpreted as actual reported values.
  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

interface ITreasury {
    function deposit( uint _amount, address _token, uint _profit ) external returns ( bool );
    function valueOf( address _token, uint _amount ) external view returns ( uint value_ );
    function mintRewards( address _recipient, uint _amount ) external;
}

interface IStaking {
    function stake( uint _amount, address _recipient ) external returns ( bool );
}

interface IStakingHelper {
    function stake( uint _amount, address _recipient ) external;
}

contract wAVAXAKITABondDepository is Ownable {


     using SafeERC20 for IERC20;

    /* ======== EVENTS ======== */

    event BondCreated( uint deposit, uint indexed payout, uint indexed expires, uint indexed priceInUSD );
    event BondRedeemed( address indexed recipient, uint payout, uint remaining );
    event BondPriceChanged( uint indexed priceInUSD, uint indexed internalPrice, uint indexed debtRatio );
    event ControlVariableAdjustment( uint initialBCV, uint newBCV, uint adjustment, bool addition );




    /* ======== STATE VARIABLES ======== */

    IERC20 public AKITA; // token given as payment for bond
    IERC20 public principle; // token used to create bond
    address public immutable treasury; // mints AKITA when receives principle
    address public immutable DAO; // receives profit share from bond

    AggregatorV3Interface internal priceFeed;

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
        uint minimumPrice; // vs principle value. 4 decimals (1500 = 0.15)
        uint maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
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
        address _feed
    ) {
        require( address(_AKITA) != address(0) );
        AKITA = _AKITA;
        require(  address(_principle) != address(0) );
        principle = _principle;
        require( _treasury != address(0) );
        treasury = _treasury;
        require( _DAO != address(0) );
        DAO = _DAO;
        require( _feed != address(0) );
        priceFeed = AggregatorV3Interface( _feed );
    }

    /**
     *  @notice initializes bond parameters
     *  @param _controlVariable uint
     *  @param _vestingTerm uint
     *  @param _minimumPrice uint
     *  @param _maxPayout uint
     *  @param _maxDebt uint
     *  @param _initialDebt uint
     */
    function initializeBondTerms( 
        uint _controlVariable, 
        uint _vestingTerm,
        uint _minimumPrice,
        uint _maxPayout,
        uint _maxDebt,
        uint _initialDebt
    ) external onlyPolicy() initializeNotTimeLocked {
        require( currentDebt() == 0, "Debt must be 0 for initialization" );
        require( _maxPayout <= 1000, "Payout cannot be above 1 percent" );
        terms = Terms ({
            controlVariable: _controlVariable,
            vestingTerm: _vestingTerm,
            minimumPrice: _minimumPrice,
            maxPayout: _maxPayout,
            maxDebt: _maxDebt
        });
        totalDebt = _initialDebt;
        lastDecay = block.number;
        initializeTimelock = 0;
    }



    
    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER { VESTING, PAYOUT, DEBT }
    /**
     *  @notice set parameters for new bonds
     *  @param _parameter PARAMETER
     *  @param _input uint
     */
    function setBondTerms ( PARAMETER _parameter, uint _input ) external onlyPolicy() setBondTermNotTimeLocked {
        if ( _parameter == PARAMETER.PAYOUT ) { // 1
            require( _input <= 1000, "Payout cannot be above 1 percent" );
            terms.maxPayout = _input;
        } else if ( _parameter == PARAMETER.DEBT ) { // 3
            terms.maxDebt = _input;
        }
        setBondTermTimelock = 0;
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
    ) external onlyPolicy() setAdjustmentNotTimeLocked {
        require( _increment <= Fixidity.fromFixed( Fixidity.divide(
            Fixidity.mul(Fixidity.newFixed(terms.controlVariable), Fixidity.newFixed(25) ) , 
            Fixidity.newFixed(1000) ) ), 
            "Increment too large" );
//TODO: Review if newFixed(1000) or 10000
        adjustment = Adjust({
            add: _addition,
            rate: _increment,
            target: _target,
            buffer: _buffer,
            lastBlock: block.number
        });
        setAdjustmentTimelock = 0;
    }

    /**
     *  @notice set contract for auto stake
     *  @param _staking address
     *  @param _helper bool
     */
    function setStaking( address _staking, bool _helper ) external onlyPolicy() setStakingNotTimeLocked {
        require( _staking != address(0) );
        if ( _helper ) {
            useHelper = true;
            stakingHelper = _staking;
        } else {
            useHelper = false;
            staking = _staking;
        }
        setStakingTimelock = 0;
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
        require( totalDebt <= terms.maxDebt, "Max capacity reached" );
        
        uint priceInUSD = bondPriceInUSD(); // Stored in bond info
        uint nativePrice = _bondPrice();

        require( _maxPrice >= nativePrice, "Slippage limit: more than max price" ); // slippage protection

        uint value = ITreasury( treasury ).valueOf( address(principle), _amount );
        uint payout = payoutFor( value ); // payout to bonder is computed

        require( payout >= 10000000, "Bond too small" ); // must be > 0.01 AKITA ( underflow protection )
        require( payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        /**
            asset carries risk and is not minted against
            asset transfered to treasury and rewards minted as payout
         */
        principle.safeTransferFrom( msg.sender, treasury, _amount );
        ITreasury( treasury ).mintRewards( address(this), payout );
        
        // total debt is increased
        totalDebt = totalDebt + value;
                
        // depositor info is stored
        bondInfo[ _depositor ] = Bond({ 
            payout: bondInfo[ _depositor ].payout + payout,
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
            uint payout = Fixidity.fromFixed(Fixidity.divide(
                Fixidity.mul(
                    Fixidity.newFixed(percentVested),Fixidity.newFixed(info.payout)),Fixidity.newFixed(10000)));

            // store updated deposit info
            bondInfo[ _recipient ] = Bond({
                payout: info.payout - payout,
                vesting: info.vesting - (block.number - info.lastBlock),
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
        return Fixidity.fromFixed( Fixidity.divide(
            Fixidity.mul(Fixidity.newFixed(AKITA.totalSupply()), Fixidity.newFixed(terms.maxPayout) ) , 
            Fixidity.newFixed(100000) ) );
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param _value uint
     *  @return uint
     */
    function payoutFor( uint _value ) public view returns ( uint ) {
        return Fixidity.fromFixed( Fixidity.divide(
            Fixidity.newFixedFraction(_value, bondPrice()), 
            Fixidity.newFixed(1e14) ) );
    }


    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() public view returns ( uint price_ ) {        
        price_ = Fixidity.fromFixed( Fixidity.divide(
            Fixidity.mul(Fixidity.newFixed(terms.controlVariable), Fixidity.newFixed(debtRatio())), 
            Fixidity.newFixed(1e5) ) );
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;
        }
    }

    /**
     *  @notice calculate current bond price and remove floor if above
     *  @return price_ uint
     */
    function _bondPrice() internal returns ( uint price_ ) {
        price_ = Fixidity.fromFixed( Fixidity.divide(
            Fixidity.mul(Fixidity.newFixed(terms.controlVariable), Fixidity.newFixed(debtRatio())), 
            Fixidity.newFixed(1e5) ) );
        if ( price_ < terms.minimumPrice ) {
            price_ = terms.minimumPrice;        
        } else if ( terms.minimumPrice != 0 ) {
            terms.minimumPrice = 0;
        }
    }

    /**
     *  @notice get asset price from chainlink
     */
    function assetPrice() public view returns (int) {
        ( , int price, , , ) = priceFeed.latestRoundData();
        return price;
    }

    /**
     *  @notice converts bond price to DAI value
     *  @return price_ uint
     */
    function bondPriceInUSD() public view returns ( uint price_ ) {
        price_ = bondPrice() * uint(assetPrice()) * 1e6;  
    }

    /**
     *  @notice calculate current ratio of debt to AKITA supply
     *  @return debtRatio_ uint
     */
    function debtRatio() public view returns ( uint debtRatio_ ) {   
        uint supply = AKITA.totalSupply();
        debtRatio_ = Fixidity.fromFixed(Fixidity.divide(
            Fixidity.newFixedFraction(
                Fixidity.fromFixed(Fixidity.mul( Fixidity.newFixed(currentDebt()) , Fixidity.newFixed(1e9))),
                supply),
                Fixidity.newFixed(1e18)));
    }

    /**
     *  @notice debt ratio in same terms as reserve bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns ( uint ) {
        return Fixidity.fromFixed( Fixidity.divide(
            Fixidity.mul(Fixidity.newFixed(debtRatio()), Fixidity.newFixed(uint( assetPrice() ))), 
            Fixidity.newFixed(1e8) ) ); // ETH feed is 8 decimals
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns ( uint ) {
        return totalDebt - debtDecay();
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     */
    function debtDecay() public view returns ( uint decay_ ) {
        uint blocksSinceLast = block.number - lastDecay;
        decay_ = Fixidity.fromFixed( Fixidity.divide(
            Fixidity.mul(Fixidity.newFixed(totalDebt), Fixidity.newFixed(blocksSinceLast)), 
            Fixidity.newFixed(terms.vestingTerm) ) );
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
            percentVested_ = Fixidity.fromFixed( Fixidity.divide(
            Fixidity.mul(Fixidity.newFixed(blocksSinceLast), Fixidity.newFixed(10000)), 
            Fixidity.newFixed(vesting) ) );
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
            pendingPayout_ = Fixidity.fromFixed( Fixidity.divide(
            Fixidity.mul(Fixidity.newFixed(payout), Fixidity.newFixed(percentVested)), 
            Fixidity.newFixed(10000) ) );
        }
    }




    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or AKITA) to the DAO
     *  @return bool
     */
    function recoverLostToken( address _token ) external returns ( bool ) {
        require( _token != address(AKITA) );
        require( _token != address(principle) );
         IERC20(_token).safeTransfer( DAO,  ERC20(_token).balanceOf( address(this) ) );
        return true;
    }

    /* ======== TIMELOCK FUNCTIONS ======== */

    uint256 private constant _TIMELOCK = 2 days;
    uint256 public initializeTimelock = 0;
    uint256 public setBondTermTimelock = 0;
    uint256 public setAdjustmentTimelock = 0;
    uint256 public setStakingTimelock = 0;

    modifier initializeNotTimeLocked() {
        require(initializeTimelock != 0 && initializeTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openInitializeTimeLock() external onlyPolicy() {
        initializeTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelInitializeTimeLock() external onlyPolicy() {
        initializeTimelock = 0;
    }

    modifier setBondTermNotTimeLocked() {
        require(setBondTermTimelock != 0 && setBondTermTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetBondTermTimeLock() external onlyPolicy() {
        setBondTermTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetBondTermTimeLock() external onlyPolicy() {
        setBondTermTimelock = 0;
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

    modifier setStakingNotTimeLocked() {
        require(setStakingTimelock != 0 && setStakingTimelock <= block.timestamp, "Timelocked");
        _;
    }

    function openSetStakingTimeLock() external onlyPolicy() {
        setStakingTimelock = block.timestamp + _TIMELOCK;
    }

    function cancelSetStakingTimeLock() external onlyPolicy() {
        setStakingTimelock = 0;
    }
}