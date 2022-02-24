// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.10;

import "./Fixidity.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";



library Babylonian {

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1; // Seven iterations should be enough
        uint256 r1 = x / r;
        return (r < r1 ? r : r1);
    }
}

interface IUniswapV2ERC20 {
    function totalSupply() external view returns (uint);
}


interface IUniswapV2Pair is IUniswapV2ERC20 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns ( address );
    function token1() external view returns ( address );
}


interface IBondingCalculator {
  function valuation( address pair_, uint amount_ ) external view returns ( uint _value );
}

contract AkitaBondingCalculator is IBondingCalculator {


    IERC20 public AKITA;

    constructor( IERC20 _AKITA ) {
        require( address(_AKITA) != address(0) );
        AKITA = _AKITA;
    }

    function getKValue( address _pair ) public view returns( uint k_ ) {
        uint token0 = IERC20Metadata(IUniswapV2Pair( _pair ).token0()).decimals();
        uint token1 = IERC20Metadata(IUniswapV2Pair( _pair ).token1()).decimals();
        uint decimals = Fixidity.fromFixed( 
            Fixidity.add( 
            Fixidity.subtract( Fixidity.newFixed(token1) , Fixidity.newFixed(IERC20Metadata( _pair ).decimals()) ), Fixidity.newFixed(token0) )
             );

        (uint reserve0, uint reserve1, ) = IUniswapV2Pair( _pair ).getReserves();
        k_ = Fixidity.fromFixed( 
            Fixidity.divide( 
            Fixidity.mul( Fixidity.newFixed(reserve0) , Fixidity.newFixed(reserve1) ), 
            Fixidity.newFixed(10 ** decimals) )
             );
    }
    // calculates the risk free value of OHM-stable LP tokens
    function getTotalValue( address _pair ) public view returns ( uint _value ) {
        _value = Fixidity.fromFixed(Fixidity.mul(Fixidity.newFixed(Babylonian.sqrt(getKValue(_pair))),Fixidity.newFixed(2)));
    }

    function valuation( address _pair, uint amount_ ) external view override returns ( uint _value ) {
        uint totalValue = getTotalValue( _pair );
        uint totalSupply = IUniswapV2Pair( _pair ).totalSupply();

        _value = Fixidity.fromFixed(
            Fixidity.divide(
            Fixidity.mul(
            Fixidity.newFixedFraction( amount_, totalSupply), 
            Fixidity.newFixed(totalValue)), Fixidity.newFixed(1e18)));
    }

    function markdown( address _pair ) external view returns ( uint ) {
        ( uint reserve0, uint reserve1, ) = IUniswapV2Pair( _pair ).getReserves();

        uint reserve;
        if ( IUniswapV2Pair( _pair ).token0() == address(AKITA) ) {
            reserve = reserve1;
        } else {
            reserve = reserve0;
        }
        return Fixidity.fromFixed(Fixidity.divide(
        Fixidity.mul( 
        Fixidity.newFixed(reserve), 
        Fixidity.newFixed( 2 * ( 10 ** 18 ))), 
        Fixidity.newFixed( getTotalValue( _pair ) ) ));
    }
}
